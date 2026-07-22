defmodule SymphonyElixir.DeliveryControl do
  @moduledoc "Engine-owned implementation review, publication, and completion evidence."

  alias SymphonyElixir.Linear.{Issue, TaskContract}

  alias SymphonyElixir.{
    EnginePublisher,
    ExecutionControl,
    ExecutionLedger,
    ImplementationReview,
    TaskBranch,
    WorkspaceArtifact
  }

  @completion_path Path.join(".symphony", "completion-evidence.json")
  @max_completion_bytes 131_072

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      ImplementationReview.request_tool_spec(),
      %{
        "name" => "publish_pull_request",
        "description" => "Publish the reviewed final commit through Symphony and generate trusted completion evidence.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ~w(title body),
          "properties" => %{
            "title" => %{"type" => "string", "minLength" => 1, "maxLength" => 70},
            "body" => %{"type" => "string", "minLength" => 1, "maxLength" => 65_536}
          }
        }
      }
    ]
  end

  @spec execute_tool(Path.t(), Issue.t(), TaskContract.t(), map(), String.t(), String.t(), map(), keyword()) :: map()
  def execute_tool(workspace, issue, contract, plan, key, "request_implementation_review", %{} = arguments, opts)
      when map_size(arguments) == 0 do
    ImplementationReview.request(workspace, issue, contract, plan, key, opts)
    |> tool_result()
  end

  def execute_tool(workspace, issue, contract, plan, key, "publish_pull_request", %{"title" => title, "body" => body}, opts) do
    publish(workspace, issue, contract, plan, key, title, body, opts)
    |> tool_result()
  end

  def execute_tool(_workspace, _issue, _contract, _plan, _key, tool, _arguments, _opts),
    do: tool_result({:error, {:unsupported_delivery_tool, tool}})

  @spec publish(Path.t(), Issue.t(), TaskContract.t(), map(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def publish(workspace, %Issue{} = issue, %TaskContract{} = contract, plan, key, title, body, opts \\ []) do
    publisher = Keyword.get(opts, :publisher, &EnginePublisher.publish/5)

    with {:ok, delivery} <- ExecutionControl.delivery_state(plan, key, workspace, opts),
         :ok <-
           TaskBranch.validate(
             workspace,
             issue,
             plan["workflow"],
             plan_base(plan),
             Keyword.get(opts, :worker_host)
           ),
         {:ok, review} <- required_review(plan, key, delivery.repository),
         {:ok, published} <- publisher.(workspace, plan, title, body, opts),
         true <- published["head_sha"] == delivery.repository.base_sha || {:error, :publication_review_head_drift},
         {:ok, publication} <- persist_publication(key, plan, published, delivery, review) do
      generate_completion(workspace, issue, contract, plan, key, publication, review, opts)
    end
  end

  @spec read_completion(String.t()) :: {:ok, map()} | {:error, term()}
  def read_completion(key) do
    case ExecutionLedger.read(key, "completion", "evidence") do
      {:ok, receipt} -> {:ok, receipt}
      :missing -> {:error, :completion_evidence_missing}
      {:error, reason} -> {:error, {:completion_evidence_invalid, reason}}
    end
  end

  defp required_review(plan, key, repository) do
    if ImplementationReview.required?(plan) do
      ImplementationReview.latest_approval(key, repository.base_sha, repository.digest)
    else
      {:ok, nil}
    end
  end

  defp persist_publication(key, plan, published, delivery, review) do
    receipt = %{
      "plan_digest" => plan["plan_digest"],
      "instruction_digest" => plan["instruction_digest"],
      "profile_digest" => plan["profile_digest"],
      "url" => published["url"],
      "head_sha" => published["head_sha"],
      "head_branch" => published["head_branch"],
      "base_branch" => published["base_branch"],
      "origin" => published["origin"],
      "repository_state_digest" => delivery.repository.digest,
      "final_proof_receipt_digest" => delivery.final_proof["receipt_digest"],
      "review_receipt_digest" => review && review["receipt_digest"]
    }

    case ExecutionLedger.create(key, "publication", "pull-request", receipt) do
      {:ok, persisted} -> {:ok, persisted}
      :exists -> validate_existing_publication(key, receipt)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_existing_publication(key, expected) do
    case ExecutionLedger.read_required(
           key,
           "publication",
           "pull-request",
           :publication_receipt_missing,
           :publication_receipt_invalid
         ) do
      {:ok, existing} ->
        if Map.drop(existing, ["receipt_digest"]) == expected,
          do: {:ok, existing},
          else: {:error, :publication_receipt_drift}

      {:error, _reason} = error ->
        error
    end
  end

  defp generate_completion(workspace, issue, contract, plan, key, publication, review, opts) do
    with {:ok, proof_receipts} <- ExecutionLedger.list(key, "proof"),
         {:ok, phase_receipts} <- ExecutionLedger.list(key, "phase"),
         {:ok, surgical_receipts} <- ExecutionLedger.list(key, "surgical-review"),
         {:ok, criteria} <- criterion_evidence(contract, proof_receipts, publication["head_sha"]) do
      semantic = %{
        "schema_version" => 3,
        "issue_id" => issue.id,
        "issue_identifier" => issue.identifier,
        "contract_digest" => contract.digest,
        "execution_plan_digest" => plan["plan_digest"],
        "instruction_digest" => plan["instruction_digest"],
        "workflow" => plan["workflow"],
        "profile_digest" => plan["profile_digest"],
        "repository_head_sha" => publication["head_sha"],
        "pr_head_sha" => publication["head_sha"],
        "pr_head_branch" => publication["head_branch"],
        "pr_base_branch" => publication["base_branch"],
        "pull_request_url" => publication["url"],
        "criteria" => criteria,
        "proof_receipt_digests" => Enum.map(proof_receipts, & &1["receipt_digest"]),
        "phase_receipt_digests" => Enum.map(phase_receipts, & &1["receipt_digest"]),
        "surgical_review_receipt_digest" => surgical_receipts |> List.first() |> then(&(&1 && &1["receipt_digest"])),
        "review_receipt_digest" => review && review["receipt_digest"],
        "publication_receipt_digest" => publication["receipt_digest"]
      }

      persist_completion(workspace, key, semantic, Keyword.get(opts, :worker_host))
    end
  end

  defp criterion_evidence(contract, proof_receipts, head_sha) do
    successful_final =
      Enum.filter(proof_receipts, fn receipt ->
        receipt["passed"] and receipt["role"] in ~w(final validator) and receipt["head_sha"] == head_sha
      end)

    criteria =
      Enum.map(contract.acceptance_criteria, fn criterion ->
        case Enum.find(successful_final, &(criterion.id in (&1["criterion_ids"] || []))) do
          nil ->
            {:error, {:criterion_without_fresh_final_proof, criterion.id}}

          receipt ->
            {:ok,
             %{
               "criterion_id" => criterion.id,
               "proof_receipt_digest" => receipt["receipt_digest"],
               "proof_id" => receipt["proof_id"]
             }}
        end
      end)

    case Enum.find(criteria, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(criteria, fn {:ok, item} -> item end)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_completion(workspace, key, semantic, worker_host) do
    case ExecutionLedger.create(key, "completion", "evidence", semantic) do
      {:ok, persisted} ->
        write_workspace_completion(workspace, persisted, worker_host)

      :exists ->
        with {:ok, existing} <- read_completion(key),
             true <- Map.drop(existing, ["receipt_digest"]) == semantic || {:error, :completion_evidence_drift} do
          write_workspace_completion(workspace, existing, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_workspace_completion(workspace, evidence, worker_host) do
    payload = Jason.encode!(evidence, pretty: true) <> "\n"

    if byte_size(payload) > @max_completion_bytes do
      {:error, :completion_evidence_too_large}
    else
      path = Path.join(workspace, @completion_path)

      case WorkspaceArtifact.create_exclusive(path, payload, worker_host) do
        :ok -> {:ok, evidence}
        :exists -> validate_workspace_completion(path, payload, worker_host, evidence)
        {:error, reason} -> {:error, {:completion_evidence_write_failed, reason}}
      end
    end
  end

  defp validate_workspace_completion(path, payload, worker_host, evidence) do
    case WorkspaceArtifact.read(path, @max_completion_bytes, worker_host) do
      {:ok, ^payload} -> {:ok, evidence}
      {:ok, _forged} -> {:error, :workspace_completion_evidence_collision}
      other -> {:error, {:completion_evidence_readback_failed, other}}
    end
  end

  defp tool_result({:ok, payload}) do
    output = Jason.encode!(payload, pretty: true)
    %{"success" => true, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  defp tool_result({:error, reason}) do
    output = inspect(reason)
    %{"success" => false, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  defp plan_base(%{"candidate" => %{"repository" => %{"base_sha" => sha}}}), do: sha
  defp plan_base(%{"repository" => %{"base_sha" => sha}}), do: sha
end
