defmodule SymphonyElixir.ImplementationReview do
  @moduledoc "Isolated medium-effort review bound to the final committed repository state."

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.ExecutionControl
  alias SymphonyElixir.ExecutionLedger
  alias SymphonyElixir.HumanReviewBlocker
  alias SymphonyElixir.Linear.{Issue, TaskContract}
  alias SymphonyElixir.RepositoryReviewSnapshot

  @read_only %{"type" => "readOnly", "networkAccess" => false}
  @deny "never"
  @fields ~w(verdict blocking_findings advisory_findings)

  @spec request_tool_spec() :: map()
  def request_tool_spec do
    %{
      "name" => "request_implementation_review",
      "description" => "Request Symphony's isolated final implementation review after final proof.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    }
  end

  @spec submission_tool_specs() :: [map()]
  def submission_tool_specs do
    [
      %{
        "name" => "submit_implementation_review",
        "description" => "Submit one final-state implementation review.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => @fields,
          "properties" => %{
            "verdict" => %{"type" => "string", "enum" => ~w(approve revise)},
            "blocking_findings" => findings_schema(),
            "advisory_findings" => findings_schema()
          }
        }
      }
    ]
  end

  @spec required?(map()) :: boolean()
  def required?(%{"execution_mode" => "simple", "verification_profile" => profile}), do: profile == "Full"
  def required?(_plan), do: true

  @spec required?(map(), String.t()) :: boolean()
  def required?(plan, effective_profile),
    do: effective_profile == "Full" or required?(plan)

  @spec request(Path.t(), Issue.t(), TaskContract.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def request(workspace, %Issue{} = issue, %TaskContract{} = contract, plan, ledger_key, opts \\ []) do
    with {:ok, delivery} <- ExecutionControl.delivery_state(plan, ledger_key, workspace, opts),
         true <-
           required?(plan, delivery.verification_profile.effective) ||
             {:error, :implementation_review_not_required},
         {:ok, attempt} <- next_attempt(ledger_key),
         {:ok, snapshot} <- RepositoryReviewSnapshot.capture(workspace, plan_base(plan), Keyword.get(opts, :worker_host)),
         true <- snapshot.repository.digest == delivery.repository.digest || {:error, :implementation_review_state_drift},
         {:ok, submission} <- run_reviewer(workspace, issue, contract, plan, ledger_key, snapshot, opts),
         :ok <- validate_submission(submission),
         {:ok, after_state} <- SymphonyElixir.RepositoryFingerprint.capture(workspace, Keyword.get(opts, :worker_host)),
         true <- after_state.digest == snapshot.repository.digest || {:error, :implementation_review_modified_repository},
         {:ok, receipt} <- persist_review(ledger_key, attempt, submission, plan, snapshot, delivery) do
      handle_verdict(issue, contract, ledger_key, attempt, receipt, opts)
    end
  end

  @spec latest_approval(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def latest_approval(key, head_sha, state_digest) do
    with {:ok, receipts} <- ExecutionLedger.list(key, "implementation-review") do
      receipts
      |> Enum.reverse()
      |> List.first()
      |> case do
        %{"verdict" => "approve", "head_sha" => ^head_sha, "repository_state_digest" => ^state_digest} = receipt ->
          {:ok, receipt}

        %{"verdict" => "revise"} ->
          {:error, :implementation_review_revision_required}

        nil ->
          {:error, :implementation_review_approval_required}

        _stale ->
          {:error, :implementation_review_approval_stale}
      end
    end
  end

  defp run_reviewer(workspace, issue, contract, plan, key, snapshot, opts) do
    start_session = Keyword.get(opts, :start_session, &AppServer.start_session/2)
    run_turn = Keyword.get(opts, :run_turn, &AppServer.run_turn/4)
    stop_session = Keyword.get(opts, :stop_session, &AppServer.stop_session/1)
    {:ok, collector} = Agent.start_link(fn -> %{submission: nil, file_change: false} end)

    try do
      with {:ok, session} <-
             start_session.(workspace,
               worker_host: Keyword.get(opts, :worker_host),
               dynamic_tools: submission_tool_specs()
             ) do
        try do
          result =
            run_turn.(session, review_prompt(issue, contract, plan, key, snapshot), issue,
              sandbox_policy: @read_only,
              approval_policy: @deny,
              auto_approve_requests: false,
              effort: "medium",
              on_message: fn message -> Agent.update(collector, &collect(&1, message)) end,
              tool_executor: submission_executor(collector)
            )

          collected = Agent.get(collector, & &1)

          with {:ok, _turn} <- result,
               :ok <- reject_file_change(collected.file_change),
               submission when is_map(submission) <-
                 collected.submission || {:error, :implementation_review_submission_missing} do
            {:ok, submission}
          end
        after
          stop_session.(session)
        end
      end
    after
      Agent.stop(collector)
    end
  end

  defp collect(state, %{payload: %{"method" => method}} = message) do
    file_change =
      String.contains?(method, "fileChange") or
        (method in ["item/started", "item/completed"] and get_in(message, [:payload, "params", "item", "type"]) == "fileChange")

    %{state | file_change: state.file_change or file_change}
  end

  defp collect(state, _message), do: state

  defp submission_executor(collector) do
    fn
      "submit_implementation_review", arguments when is_map(arguments) ->
        stored = Agent.get_and_update(collector, &store_submission(&1, arguments))
        response(stored, if(stored, do: "Review captured.", else: "Only one review is allowed."))

      tool, _arguments ->
        response(false, "Unsupported review tool: #{tool}")
    end
  end

  defp store_submission(%{submission: nil} = state, arguments),
    do: {true, %{state | submission: arguments}}

  defp store_submission(state, _arguments), do: {false, state}

  defp validate_submission(submission) do
    cond do
      Enum.sort(Map.keys(submission)) != Enum.sort(@fields) -> {:error, :invalid_implementation_review_fields}
      not valid_findings?(submission["blocking_findings"]) -> {:error, :invalid_implementation_review_findings}
      not valid_findings?(submission["advisory_findings"]) -> {:error, :invalid_implementation_review_findings}
      submission["verdict"] == "approve" and submission["blocking_findings"] == [] -> :ok
      submission["verdict"] == "revise" and submission["blocking_findings"] != [] -> :ok
      true -> {:error, :invalid_implementation_review_verdict}
    end
  end

  defp valid_findings?(findings) do
    is_list(findings) and length(findings) <= 64 and
      Enum.all?(findings, &(is_binary(&1) and byte_size(&1) in 1..8192))
  end

  defp persist_review(key, attempt, submission, plan, snapshot, delivery) do
    receipt =
      Map.merge(submission, %{
        "attempt" => attempt,
        "plan_digest" => plan["plan_digest"],
        "instruction_digest" => plan["instruction_digest"],
        "profile_digest" => plan["profile_digest"],
        "head_sha" => snapshot.repository.base_sha,
        "repository_state_digest" => snapshot.repository.digest,
        "final_proof_receipt_digest" => delivery.final_proof["receipt_digest"]
      })

    case ExecutionLedger.create(key, "implementation-review", "review-#{attempt}", receipt) do
      {:ok, persisted} -> {:ok, persisted}
      :exists -> {:error, :implementation_review_attempt_collision}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_verdict(_issue, _contract, _key, _attempt, %{"verdict" => "approve"} = receipt, _opts),
    do: {:ok, receipt}

  defp handle_verdict(_issue, _contract, _key, attempt, %{"verdict" => "revise"} = receipt, _opts)
       when attempt < 3,
       do: {:ok, receipt}

  defp handle_verdict(issue, contract, key, 3, %{"verdict" => "revise"} = receipt, opts) do
    handler = Keyword.get(opts, :exhausted_handler, &publish_exhaustion/4)
    handler.(issue, contract, key, receipt)
  end

  defp publish_exhaustion(issue, contract, key, receipt) do
    body =
      "## Agent Blocked\n\nAutomated implementation review requested revision three times. " <>
        "Human Review is required.\n\n" <>
        Enum.map_join(receipt["blocking_findings"], "\n", &"- #{&1}")

    case HumanReviewBlocker.publish(issue, [contract.digest, key, receipt["receipt_digest"]], body) do
      {:ok, comment_id} -> {:error, {:implementation_review_exhausted, comment_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_attempt(key) do
    case Enum.find(1..3, &(ExecutionLedger.read(key, "implementation-review", "review-#{&1}") == :missing)) do
      nil -> {:error, :implementation_review_attempts_exhausted}
      attempt -> {:ok, attempt}
    end
  end

  defp reject_file_change(false), do: :ok
  defp reject_file_change(true), do: {:error, :implementation_review_file_change}

  defp review_prompt(issue, contract, plan, key, snapshot) do
    proofs = proof_summaries(key)

    """
    Review the final implementation for #{issue.identifier} in read-only mode. Call submit_implementation_review exactly once.
    Check correctness, security, scope, execution scale, cross-adapter drift, test-runner coverage, workflow invariants, and proof sufficiency.
    Contract: #{contract.description}
    Instruction digest: #{plan["instruction_digest"]}
    Profile digest: #{plan["profile_digest"]}
    Plan: #{Jason.encode!(plan, pretty: true)}
    Changed paths: #{Jason.encode!(snapshot.changed_paths)}
    Execution context: #{get_in(plan, ["candidate", "execution_context"])}
    Scale shape: #{get_in(plan, ["candidate", "scale_shape"])}
    Proof summaries: #{Jason.encode!(proofs, pretty: true)}
    Base-to-head diff:\n#{snapshot.diff}
    """
  end

  defp proof_summaries(key) do
    case ExecutionLedger.list(key, "proof") do
      {:ok, receipts} ->
        Enum.map(receipts, &Map.take(&1, ~w(proof_id role passed head_sha output_hash)))

      {:error, reason} ->
        [%{"ledger_error" => inspect(reason)}]
    end
  end

  defp response(success, output), do: %{"success" => success, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  defp findings_schema, do: %{"type" => "array", "maxItems" => 64, "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 8192}}
  defp plan_base(%{"candidate" => %{"repository" => %{"base_sha" => sha}}}), do: sha
end
