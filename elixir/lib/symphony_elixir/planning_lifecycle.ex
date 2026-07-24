defmodule SymphonyElixir.PlanningLifecycle do
  @moduledoc """
  Runs the bounded, read-only plan and review lifecycle before goal activation.
  """

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Linear.{Issue, TaskContract}
  alias SymphonyElixir.{PlanningArtifact, PlanningGate, RepositoryFingerprint, Tracker, WorkflowProfile}

  @max_revisions 3
  @read_only_policy %{"type" => "readOnly", "networkAccess" => false}
  @deny_approvals "never"

  @spec run(map(), Path.t(), Issue.t(), TaskContract.t(), WorkflowProfile.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(primary_session, workspace, issue, contract, profile, opts \\ []) do
    opts = Keyword.put(opts, :planning_workspace, workspace)
    run_new(primary_session, workspace, issue, contract, profile, opts)
  end

  defp run_new(primary_session, workspace, issue, contract, profile, opts) do
    worker_host = Keyword.get(opts, :worker_host)
    capture = Keyword.get(opts, :repository_capture, &RepositoryFingerprint.capture/2)

    with {:ok, repository} <- capture.(workspace, worker_host),
         authority <- authority_context(issue, contract, profile, primary_session.thread_id, repository, opts) do
      context = context(issue, contract, profile, primary_session.thread_id, repository, authority)

      case PlanningArtifact.read_execution_plan(workspace, worker_host, context["authority_digest"]) do
        {:ok, plan} -> validate_execution_plan(plan, issue, contract, profile, primary_session.thread_id, context)
        :missing -> start_new_authority(primary_session, workspace, issue, contract, profile, repository, context, opts)
        {:error, _reason} = error -> error
      end
    end
  end

  defp start_new_authority(primary_session, workspace, issue, contract, profile, repository, context, opts) do
    worker_host = Keyword.get(opts, :worker_host)

    with true <- Map.get(repository, :clean, true) || {:error, :preactivation_repository_not_clean},
         {:ok, classification} <-
           PlanningGate.classify(
             workspace,
             issue,
             contract,
             profile,
             primary_session.thread_id,
             repository,
             worker_host,
             context
           ) do
      emit_lifecycle(opts, :task_classified, %{
        phase: "classification",
        status: "completed",
        category: classification["category"],
        classification_digest: classification["classification_digest"]
      })

      route_classification(
        classification,
        primary_session,
        workspace,
        issue,
        contract,
        profile,
        context,
        opts
      )
    end
  end

  defp route_classification(
         %{"category" => "simple"} = classification,
         _primary_session,
         workspace,
         issue,
         contract,
         profile,
         context,
         opts
       ) do
    with :ok <- revalidate_authority(issue, contract, profile, context, opts) do
      PlanningArtifact.seal_simple(
        workspace,
        classification,
        Keyword.get(opts, :worker_host)
      )
    end
  end

  defp route_classification(
         %{"category" => "planned"},
         primary_session,
         workspace,
         issue,
         contract,
         profile,
         context,
         opts
       ) do
    run_revision(primary_session, workspace, issue, contract, profile, context, 1, opts)
  end

  defp run_revision(primary_session, workspace, issue, contract, profile, context, revision, opts) do
    with {:ok, candidate} <-
           candidate_for_revision(
             primary_session,
             workspace,
             issue,
             contract,
             profile,
             context,
             revision,
             opts
           ),
         :ok <- pin_primary_thread(opts) do
      authority = %{issue: issue, contract: contract, profile: profile, context: context}
      review_candidate(primary_session, workspace, authority, candidate, revision, opts)
    end
  end

  defp pin_primary_thread(opts) do
    case Keyword.get(opts, :pin_primary_thread) do
      nil -> :ok
      callback when is_function(callback, 0) -> callback.()
    end
  end

  defp review_candidate(
         primary_session,
         workspace,
         authority,
         candidate,
         revision,
         opts
       ) do
    case review_for_revision(
           workspace,
           authority.issue,
           authority.contract,
           authority.profile,
           authority.context,
           candidate,
           revision,
           opts
         ) do
      {:ok, review} ->
        handle_review_verdict(
          primary_session,
          workspace,
          authority,
          candidate,
          review,
          revision,
          opts
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp handle_review_verdict(
         _primary_session,
         workspace,
         authority,
         candidate,
         %{"verdict" => "approve"} = review,
         _revision,
         opts
       ) do
    with :ok <-
           revalidate_authority(
             authority.issue,
             authority.contract,
             authority.profile,
             authority.context,
             opts
           ) do
      PlanningArtifact.seal(workspace, candidate, review, Keyword.get(opts, :worker_host))
    end
  end

  defp handle_review_verdict(
         primary_session,
         workspace,
         authority,
         candidate,
         %{"verdict" => "revise"} = review,
         revision,
         opts
       )
       when revision < @max_revisions do
    emit_lifecycle(opts, :execution_plan_revising, %{
      phase: "revising",
      status: "started",
      revision: revision + 1,
      candidate_digest: candidate["candidate_digest"]
    })

    run_revision(
      primary_session,
      workspace,
      authority.issue,
      authority.contract,
      authority.profile,
      authority.context,
      revision + 1,
      Keyword.put(opts, :review_findings, review["blocking_findings"])
    )
  end

  defp handle_review_verdict(
         _primary_session,
         _workspace,
         authority,
         candidate,
         %{"verdict" => "revise"} = review,
         _revision,
         opts
       ) do
    exhaust_review(authority.issue, authority.contract, candidate, review, opts)
  end

  defp candidate_for_revision(
         primary_session,
         workspace,
         issue,
         contract,
         profile,
         context,
         revision,
         opts
       ) do
    worker_host = Keyword.get(opts, :worker_host)

    case PlanningArtifact.read_candidate(workspace, revision, worker_host, context["authority_digest"]) do
      {:ok, candidate} -> validate_existing_candidate(candidate, context, revision)
      :missing -> run_planning_turn(primary_session, workspace, issue, contract, profile, context, revision, opts)
      {:error, _reason} = error -> error
    end
  end

  defp run_planning_turn(primary_session, workspace, issue, contract, profile, context, revision, opts) do
    capture = Keyword.get(opts, :repository_capture, &RepositoryFingerprint.capture/2)
    run_turn = Keyword.get(opts, :run_turn, &AppServer.run_turn/4)
    worker_host = Keyword.get(opts, :worker_host)
    base_on_message = Keyword.get(opts, :on_message, fn _message -> :ok end)
    {:ok, collector} = Agent.start_link(fn -> %{native_plan: nil, submission: nil, file_change: false} end)

    try do
      emit_lifecycle(opts, :execution_plan_planning_started, %{
        phase: "planning",
        status: "started",
        revision: revision
      })

      prompt = planning_prompt(issue, contract, profile, context, revision, Keyword.get(opts, :review_findings))

      turn_result =
        run_turn.(primary_session, prompt, issue,
          sandbox_policy: @read_only_policy,
          approval_policy: @deny_approvals,
          auto_approve_requests: false,
          on_message: planning_message_handler(collector, base_on_message),
          tool_executor: submission_executor(collector, "submit_execution_plan", :submission)
        )

      collected = Agent.get(collector, & &1)

      with {:ok, _turn} <- turn_result,
           :ok <- reject_file_change(collected.file_change),
           native_plan when is_list(native_plan) <- collected.native_plan || {:error, :native_plan_update_missing},
           submission when is_map(submission) <- collected.submission || {:error, :execution_plan_submission_missing},
           {:ok, repository_after} <- capture.(workspace, worker_host),
           :ok <- validate_repository_context(repository_after, context),
           {:ok, candidate} <-
             PlanningArtifact.persist_candidate(
               workspace,
               revision,
               submission,
               context,
               native_plan,
               worker_host
             ) do
        emit_lifecycle(opts, :execution_plan_candidate_persisted, %{
          phase: "planning",
          status: "completed",
          revision: revision,
          candidate_digest: candidate["candidate_digest"]
        })

        {:ok, candidate}
      end
    after
      Agent.stop(collector)
    end
  end

  defp review_for_revision(workspace, issue, contract, profile, context, candidate, revision, opts) do
    worker_host = Keyword.get(opts, :worker_host)

    case PlanningArtifact.read_review(workspace, revision, worker_host, context["authority_digest"]) do
      {:ok, review} -> validate_existing_review(review, candidate, context, revision)
      :missing -> run_review_turn(workspace, issue, contract, profile, context, candidate, revision, opts)
      {:error, _reason} = error -> error
    end
  end

  defp run_review_turn(workspace, issue, contract, profile, context, candidate, revision, opts) do
    capture = Keyword.get(opts, :repository_capture, &RepositoryFingerprint.capture/2)
    run_turn = Keyword.get(opts, :run_turn, &AppServer.run_turn/4)
    start_session = Keyword.get(opts, :start_reviewer_session, &AppServer.start_session/2)
    stop_session = Keyword.get(opts, :stop_session, &AppServer.stop_session/1)
    worker_host = Keyword.get(opts, :worker_host)
    base_on_message = Keyword.get(opts, :on_message, fn _message -> :ok end)

    with {:ok, repository_before} <- capture.(workspace, worker_host),
         :ok <- validate_repository_context(repository_before, context),
         {:ok, reviewer_session} <-
           start_session.(workspace,
             worker_host: worker_host,
             dynamic_tools: PlanningArtifact.review_tool_specs()
           ) do
      {:ok, collector} = Agent.start_link(fn -> %{submission: nil, file_change: false} end)

      try do
        emit_lifecycle(opts, :execution_plan_review_started, %{
          phase: "reviewing",
          status: "started",
          revision: revision,
          candidate_digest: candidate["candidate_digest"]
        })

        turn_result =
          run_turn.(reviewer_session, review_prompt(issue, contract, profile, candidate), issue,
            sandbox_policy: @read_only_policy,
            approval_policy: @deny_approvals,
            auto_approve_requests: false,
            effort: "medium",
            on_message: planning_message_handler(collector, base_on_message),
            tool_executor: submission_executor(collector, "submit_plan_review", :submission)
          )

        collected = Agent.get(collector, & &1)

        with {:ok, _turn} <- turn_result,
             :ok <- reject_file_change(collected.file_change),
             submission when is_map(submission) <-
               collected.submission || {:error, :plan_review_submission_missing},
             {:ok, repository_after} <- capture.(workspace, worker_host),
             :ok <- validate_repository_context(repository_after, context),
             {:ok, review} <-
               PlanningArtifact.persist_review(
                 workspace,
                 revision,
                 submission,
                 candidate,
                 context,
                 worker_host
               ) do
          emit_lifecycle(opts, :execution_plan_review_persisted, %{
            phase: "reviewing",
            status: "completed",
            revision: revision,
            verdict: review["verdict"],
            candidate_digest: candidate["candidate_digest"]
          })

          {:ok, review}
        end
      after
        Agent.stop(collector)
        stop_session.(reviewer_session)
      end
    end
  end

  defp revalidate_authority(issue, contract, profile, context, opts) do
    fetcher = Keyword.get(opts, :issue_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    capture = Keyword.get(opts, :repository_capture, &RepositoryFingerprint.capture/2)
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, [%Issue{} = refreshed | _]} <- fetcher.([issue.id]),
         {:ok, refreshed_contract} <- TaskContract.from_issue(refreshed),
         true <- refreshed_contract.digest == contract.digest || {:error, :preactivation_contract_drift},
         {:ok, refreshed_profile} <- WorkflowProfile.select(refreshed_contract),
         true <- refreshed_profile.digest == profile.digest || {:error, :preactivation_profile_drift},
         :ok <- revalidate_instructions(opts),
         {:ok, repository} <- capture.(context_workspace(opts), worker_host),
         :ok <- validate_repository_context(repository, context) do
      :ok
    else
      {:ok, []} -> {:error, :preactivation_issue_missing}
      {:error, _reason} = error -> error
    end
  end

  defp context_workspace(opts), do: Keyword.fetch!(opts, :planning_workspace)

  defp exhaust_review(issue, contract, candidate, review, opts) do
    handler = Keyword.get(opts, :review_exhausted_handler, &publish_review_exhaustion/4)
    handler.(issue, contract, candidate, review)
  end

  defp publish_review_exhaustion(issue, contract, candidate, review) do
    comment_id = blocked_comment_id(issue.id, contract.digest, candidate["candidate_digest"])

    body =
      """
      ## Agent Blocked

      Automated execution-plan review requested revision three times. Human review is required before implementation.

      Blocking findings:
      #{Enum.map_join(review["blocking_findings"], "\n", &"- #{&1}")}

      <!-- symphony-plan-blocked:v1 candidate=#{candidate["candidate_digest"]} -->
      """
      |> String.trim()

    handoff_state = SymphonyElixir.Config.settings!().tracker.handoff_state

    with :ok <- ensure_blocked_comment(issue.id, comment_id, body),
         :ok <- Tracker.update_issue_state(issue.id, handoff_state),
         {:ok, [%Issue{state: state} | _]} <- Tracker.fetch_issue_states_by_ids([issue.id]),
         true <- String.downcase(state) == String.downcase(handoff_state) || {:error, :blocked_state_readback_failed} do
      {:error, {:plan_review_exhausted, comment_id}}
    end
  end

  defp ensure_blocked_comment(issue_id, comment_id, body) do
    case Tracker.fetch_comment(issue_id, comment_id) do
      {:ok, nil} ->
        with :ok <- Tracker.create_comment(issue_id, comment_id, body),
             {:ok, %{id: ^comment_id, body: ^body}} <- Tracker.fetch_comment(issue_id, comment_id),
             do: :ok

      {:ok, %{id: ^comment_id, body: ^body}} ->
        :ok

      {:ok, %{id: ^comment_id}} ->
        {:error, :blocked_comment_collision}

      {:error, _reason} = error ->
        error
    end
  end

  defp blocked_comment_id(issue_id, contract_digest, candidate_digest) do
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> =
      :crypto.hash(:sha256, [issue_id, contract_digest, candidate_digest])

    Enum.join(
      [hex(a, 8), hex(b, 4), hex(Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000), 4), hex(Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000), 4), hex(e, 12)],
      "-"
    )
  end

  defp hex(value, width), do: value |> Integer.to_string(16) |> String.pad_leading(width, "0")

  defp validate_execution_plan(plan, issue, contract, profile, thread_id, context) do
    expected_digest = plan |> Map.delete("plan_digest") |> PlanningArtifact.digest()

    cond do
      plan["plan_digest"] != expected_digest -> {:error, :execution_plan_digest_mismatch}
      plan["issue_id"] != issue.id -> {:error, :execution_plan_issue_drift}
      plan["contract_digest"] != contract.digest -> {:error, :execution_plan_contract_drift}
      plan["profile_digest"] != profile.digest -> {:error, :execution_plan_profile_drift}
      plan["primary_thread_id"] != thread_id -> {:error, :execution_plan_thread_drift}
      plan["instruction_digest"] != context["instruction_digest"] -> {:error, :execution_plan_instruction_drift}
      plan["authority_digest"] != context["authority_digest"] -> {:error, :execution_plan_authority_drift}
      true -> {:ok, plan}
    end
  end

  defp validate_existing_candidate(candidate, context, revision) do
    cond do
      candidate["revision"] != revision ->
        {:error, :candidate_revision_drift}

      candidate["candidate_digest"] != PlanningArtifact.digest(Map.drop(candidate, ["schema_version", "revision", "candidate_digest"])) ->
        {:error, :candidate_digest_mismatch}

      Enum.any?(
        ~w(issue_id issue_identifier contract_digest workflow profile_digest primary_thread_id repository instruction_digest authority_digest),
        &(Map.has_key?(context, &1) and candidate[&1] != context[&1])
      ) ->
        {:error, :candidate_context_drift}

      true ->
        {:ok, candidate}
    end
  end

  defp validate_existing_review(review, candidate, context, revision) do
    cond do
      review["revision"] != revision ->
        {:error, :review_revision_drift}

      review["review_digest"] !=
          PlanningArtifact.digest(Map.drop(review, ["schema_version", "revision", "review_digest"])) ->
        {:error, :review_digest_mismatch}

      review["candidate_digest"] != candidate["candidate_digest"] ->
        {:error, :review_candidate_mismatch}

      review["profile_digest"] != context["profile_digest"] ->
        {:error, :review_profile_mismatch}

      true ->
        {:ok, review}
    end
  end

  defp context(issue, contract, profile, thread_id, repository, authority) do
    %{
      "issue_id" => issue.id,
      "issue_identifier" => issue.identifier,
      "contract_digest" => contract.digest,
      "workflow" => profile.name,
      "profile_digest" => profile.digest,
      "criterion_ids" => Enum.map(contract.acceptance_criteria, & &1.id),
      "primary_thread_id" => thread_id,
      "repository" => %{
        "origin" => repository.origin,
        "base_sha" => repository.base_sha,
        "preactivation_digest" => repository.digest
      }
    }
    |> Map.merge(Map.new(authority, fn {key, value} -> {to_string(key), value} end))
  end

  defp authority_context(issue, contract, profile, thread_id, repository, opts) do
    case Keyword.get(opts, :instruction_authority) do
      nil ->
        %{}

      %{digest: instruction_digest} ->
        authority_digest =
          PlanningArtifact.digest([
            issue.id,
            contract.digest,
            profile.digest,
            thread_id,
            repository.origin,
            instruction_digest
          ])

        %{instruction_digest: instruction_digest, authority_digest: authority_digest}
    end
  end

  defp revalidate_instructions(opts) do
    case Keyword.get(opts, :instruction_authority) do
      nil -> :ok
      authority -> SymphonyElixir.InstructionAuthority.revalidate(authority)
    end
  end

  defp repository_matches_context?(repository, context) do
    repository.origin == get_in(context, ["repository", "origin"]) and
      repository.base_sha == get_in(context, ["repository", "base_sha"]) and
      repository.digest == get_in(context, ["repository", "preactivation_digest"])
  end

  defp validate_repository_context(repository, context) do
    if repository_matches_context?(repository, context),
      do: :ok,
      else: {:error, :preactivation_repository_drift}
  end

  defp reject_file_change(true), do: {:error, :preactivation_file_change}
  defp reject_file_change(false), do: :ok

  defp planning_message_handler(collector, downstream) do
    fn message ->
      Agent.update(collector, &collect_message(&1, message))
      downstream.(message)
    end
  end

  defp collect_message(state, %{payload: %{"method" => "turn/plan/updated", "params" => params}}) do
    plan = params["plan"] || params["steps"] || params["items"]
    if is_list(plan), do: %{state | native_plan: plan}, else: state
  end

  defp collect_message(state, %{payload: %{"method" => method}} = message) when is_binary(method) do
    if file_change_event?(method, message), do: Map.put(state, :file_change, true), else: state
  end

  defp collect_message(state, _message), do: state

  defp file_change_event?(method, message) when method in ["item/started", "item/completed"] do
    get_in(message, [:payload, "params", "item", "type"]) == "fileChange"
  end

  defp file_change_event?(method, _message) when is_binary(method) do
    String.contains?(method, "fileChange")
  end

  defp submission_executor(collector, expected_tool, field) do
    fn tool, arguments ->
      cond do
        tool != expected_tool ->
          tool_response(false, "Unsupported planning tool: #{inspect(tool)}")

        not is_map(arguments) ->
          tool_response(false, "Submission must be a JSON object.")

        true ->
          capture_submission(collector, field, arguments)
      end
    end
  end

  defp capture_submission(collector, field, arguments) do
    stored =
      Agent.get_and_update(collector, fn state ->
        case Map.get(state, field) do
          nil -> {true, Map.put(state, field, arguments)}
          _existing -> {false, state}
        end
      end)

    if stored,
      do: tool_response(true, "Submission captured."),
      else: tool_response(false, "Only one submission is allowed per turn.")
  end

  defp tool_response(success, output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp emit_lifecycle(opts, event, attrs) do
    case Keyword.get(opts, :lifecycle_event) do
      sink when is_function(sink, 2) -> sink.(event, attrs)
      _other -> :ok
    end
  end

  defp planning_prompt(issue, contract, profile, context, revision, findings) do
    revision_guidance =
      case findings do
        findings when is_list(findings) and findings != [] ->
          "Revise the prior plan only for these blocking findings:\n" <> Enum.map_join(findings, "\n", &"- #{&1}")

        _ ->
          "Create the first execution plan for this task."
      end

    """
    You are in Symphony's read-only preactivation planning turn #{revision}/#{@max_revisions}.
    No goal is active. Do not edit files, create branches, commit, push, call external mutation APIs, request approval, or ask the operator questions.
    Inspect only the bounded repository context needed to plan. Use the native plan tool and finish with one final plan update.
    Then call `submit_execution_plan` exactly once. Its ordered_steps must exactly match that final native plan update by step text and order.
    Treat every ordered step as an independently verifiable execution phase. Give it a stable id, only prior-phase dependencies, affected paths, verification profile, proof IDs, criterion IDs, invariants, stop conditions, and evidence requirements.
    Define every command proof with exactly id, phase_id, role, exact command, safe repository-relative working_directory, expected_exit, timeout_ms, and criterion_ids. For a local browser-rendering proof, add type `browser` and browser `{url, ready_text, snapshot_contains}`: command starts only the fixture, url must be an explicit `http://127.0.0.1:<nonprivileged-port>/...` target, ready_text is its literal readiness marker, and snapshot_contains lists the literal accessibility-snapshot assertions. Do not put browser transports, tool names, JavaScript, filenames, or session identifiers in a proof. Every criterion must be covered. Set red_policy to required or waived; waived requires a concrete red_waiver_rationale.

    #{revision_guidance}

    Linear issue: #{issue.identifier} — #{issue.title}
    Contract digest: #{contract.digest}
    Contract:
    #{contract.description}

    Trusted workflow: #{profile.name} (#{profile.digest})
    #{profile.instructions}

    Engine-pinned identity fields for the submission:
    #{Jason.encode!(context, pretty: true)}
    """
    |> String.trim()
  end

  defp review_prompt(issue, contract, profile, candidate) do
    """
    You are Symphony's isolated automated execution-plan reviewer. Review only; do not edit files, request approval, ask the operator, or call external mutation APIs.
    Check contract and acceptance-criteria alignment, bounded scope, execution context, scale safety, workflow gates, typed proof sufficiency and safety, unsupported assumptions, rollback, and risky-work invariants.
    Reject phases that are not independently verifiable, depend on later work, omit meaningful stop conditions, hide scope in a broad path, or cannot map their objective to the final native plan.
    Verify every repository path named in a proof command exists at the pinned base unless that phase or an earlier phase explicitly creates that exact affected path. Reject stale or misspelled paths, and reject baseline or pre-change proofs that reference future files.
    Review only obligations owned by the approved plan. Symphony separately enforces branch/base identity, cumulative changed-path scope, conventional commits, clean final-head proof freshness, implementation review, and publication; do not demand duplicate typed proofs for those engine-owned gates unless the Linear contract explicitly requires them.
    Criterion IDs may be present on multiple diagnostic proofs. Require every criterion to be covered by at least one successful final or validator proof; do not invent an exactly-once mapping rule, and do not treat an expected failing RED proof as acceptance evidence.
    For repository-local instructional artifacts such as skills or prompts, focused static contract tests may be sufficient behavioral proof. Do not require executing an LLM, building a fake agent runtime, or performing a live external mutation unless the Linear contract explicitly requires that boundary proof.
    Call `submit_plan_review` exactly once with verdict `approve` or `revise`. An approval must have no blocking findings; a revision must have at least one concrete blocking finding.

    Linear issue: #{issue.identifier} — #{issue.title}
    Contract digest: #{contract.digest}
    Contract:
    #{contract.description}

    Trusted workflow: #{profile.name} (#{profile.digest})
    #{profile.instructions}

    Exact candidate:
    #{Jason.encode!(candidate, pretty: true)}
    """
    |> String.trim()
  end
end
