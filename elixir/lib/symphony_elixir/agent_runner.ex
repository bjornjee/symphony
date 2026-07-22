defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Codex.ThreadIdentity
  alias SymphonyElixir.CompletionEvidence
  alias SymphonyElixir.Config
  alias SymphonyElixir.ExecutionManifest
  alias SymphonyElixir.ExecutionPlanProgress
  alias SymphonyElixir.HandoffPublisher
  alias SymphonyElixir.Linear.{Issue, TaskContract}
  alias SymphonyElixir.PlanningArtifact
  alias SymphonyElixir.PlanningLifecycle
  alias SymphonyElixir.PromptBuilder
  alias SymphonyElixir.RepositoryFingerprint
  alias SymphonyElixir.RunAudit
  alias SymphonyElixir.TaskBranch
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.WorkflowProfile
  alias SymphonyElixir.Workspace

  @type worker_host :: String.t() | nil

  @doc false
  @spec goal_status_for_result_for_test({:ok, map()} | {:error, term()}) :: String.t()
  def goal_status_for_result_for_test(result), do: goal_status_for_result(result)

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), TaskContract.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, %TaskContract{} = contract, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, contract, issue_state_fetcher)
  end

  @doc false
  @spec validate_handoff_for_test(Path.t(), Issue.t(), TaskContract.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def validate_handoff_for_test(workspace, %Issue{} = issue, %TaskContract{} = contract, proofs, opts \\ [])
      when is_binary(workspace) and is_map(proofs) do
    validate_handoff(workspace, issue, contract, proofs, opts)
  end

  @doc false
  @spec handoff_after_turn_for_test(
          Path.t(),
          Issue.t(),
          Issue.t(),
          TaskContract.t(),
          map(),
          keyword()
        ) :: {:continue, Issue.t()} | {:ok, map()} | {:error, term()}
  def handoff_after_turn_for_test(
        workspace,
        %Issue{} = issue,
        %Issue{} = refreshed_issue,
        %TaskContract{} = contract,
        proofs,
        opts \\ []
      )
      when is_binary(workspace) and is_map(proofs) and is_list(opts) do
    handoff_after_turn(workspace, issue, refreshed_issue, contract, proofs, opts, 1)
  end

  @spec run(Issue.t(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    with {:ok, task_contract} <- task_contract_for_issue(issue, opts),
         {:ok, workflow_profile} <- WorkflowProfile.select(task_contract) do
      opts =
        opts
        |> Keyword.put(:task_contract, task_contract)
        |> Keyword.put(:workflow_profile, workflow_profile)

      # The orchestrator owns host retries so one worker lifetime never hops machines.
      worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

      Logger.info(
        "Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} contract_digest=#{task_contract.digest} workflow=#{workflow_profile.name} workflow_digest=#{workflow_profile.digest}"
      )

      case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
          raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
      end
    else
      {:error, errors} when is_list(errors) ->
        message = Enum.join(errors, "; ")
        Logger.warning("Task contract invalid for #{issue_context(issue)}: #{message}")
        raise RuntimeError, "Task contract invalid for #{issue_context(issue)}: #{message}"

      {:error, reason} ->
        Logger.warning("Task contract or workflow rejected for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Task contract or workflow rejected for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        task_contract = Keyword.fetch!(opts, :task_contract)

        case ExecutionManifest.pin(workspace, issue, task_contract, worker_host) do
          {:ok, manifest} ->
            RunAudit.start(workspace, issue, %{
              worker_host: worker_host_for_log(worker_host),
              plan_digest: manifest["plan_digest"]
            })

            RunAudit.append(workspace, issue, :workspace_prepared, %{
              phase: "workspace",
              status: "completed",
              workspace_path: workspace,
              plan_digest: manifest["plan_digest"]
            })

            send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace, RunAudit.paths(workspace))

            try do
              run_with_workspace(workspace, issue, codex_update_recipient, opts, worker_host)
            after
              RunAudit.append(workspace, issue, :after_run_hook_started, %{phase: "workspace", status: "started"})
              Workspace.run_after_run_hook(workspace, issue, worker_host)
              RunAudit.append(workspace, issue, :after_run_hook_completed, %{phase: "workspace", status: "completed"})
            end

          {:error, _reason} = error ->
            error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_with_workspace(workspace, issue, codex_update_recipient, opts, worker_host) do
    RunAudit.append(workspace, issue, :before_run_hook_started, %{phase: "workspace", status: "started"})

    case Workspace.run_before_run_hook(workspace, issue, worker_host) do
      :ok ->
        RunAudit.append(workspace, issue, :before_run_hook_completed, %{phase: "workspace", status: "completed"})
        result = run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
        record_run_result(workspace, issue, result)
        send_worker_completion_info(codex_update_recipient, issue, result)
        normalize_run_result(result)

      {:error, reason} = error ->
        RunAudit.append(workspace, issue, :before_run_hook_failed, %{phase: "workspace", status: "failed", reason: reason})
        error
    end
  end

  defp record_run_result(workspace, issue, {:ok, _completion_info}) do
    RunAudit.append(workspace, issue, :run_completed, %{phase: "run", status: "completed"})
  end

  defp record_run_result(workspace, issue, {:error, reason}) do
    RunAudit.append(workspace, issue, :run_failed, %{phase: "run", status: "failed", reason: reason})
  end

  defp normalize_run_result({:ok, _completion_info}), do: :ok
  defp normalize_run_result({:error, _reason} = error), do: error

  defp codex_message_handler(recipient, issue, workspace, proof_ledger, plan_progress, worker_host) do
    fn message ->
      case RunAudit.append_codex_update(workspace, issue, message) do
        {:ok, %{event_id: event_id} = proof} ->
          record_observed_proof(proof_ledger, event_id, proof, workspace, worker_host)

        {:ok, nil} ->
          :ok
      end

      record_native_plan_progress(plan_progress, message)

      send_codex_update(recipient, issue, message)
    end
  end

  defp record_native_plan_progress(
         plan_progress,
         %{payload: %{"method" => "turn/plan/updated", "params" => params}}
       ) do
    plan = params["plan"] || params["steps"] || params["items"]
    if is_list(plan), do: Agent.update(plan_progress, fn _previous -> plan end), else: :ok
  end

  defp record_native_plan_progress(_plan_progress, _message), do: :ok

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace, audit_paths)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) and is_map(audit_paths) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace,
         audit_path: audit_paths.audit_path,
         audit_events_path: audit_paths.audit_events_path
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace, _audit_paths), do: :ok

  defp send_worker_completion_info(recipient, %Issue{id: issue_id}, {:ok, completion_info})
       when is_binary(issue_id) and is_pid(recipient) and is_map(completion_info) do
    send(recipient, {:worker_completion_info, issue_id, completion_info})
    :ok
  end

  defp send_worker_completion_info(_recipient, _issue, _result), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    task_contract = Keyword.fetch!(opts, :task_contract)

    {:ok, proof_ledger} = Agent.start_link(fn -> %{} end)
    {:ok, plan_progress} = Agent.start_link(fn -> nil end)

    runtime = %{
      issue_state_fetcher: issue_state_fetcher,
      opts: opts,
      proof_ledger: proof_ledger,
      plan_progress: plan_progress,
      worker_host: worker_host
    }

    RunAudit.append(workspace, issue, :codex_app_server_starting, %{phase: "codex_app_server", status: "started"})

    try do
      case start_codex_session(workspace, worker_host) do
        {:ok, session} ->
          RunAudit.append(workspace, issue, :codex_app_server_started, %{
            phase: "codex_app_server",
            status: "completed",
            thread_id: session.thread_id
          })

          try do
            runtime = Map.put(runtime, :thread_id, session.thread_id)

            planning_opts =
              runtime.opts
              |> Keyword.put(:worker_host, worker_host)
              |> Keyword.put(
                :on_message,
                codex_message_handler(
                  codex_update_recipient,
                  issue,
                  workspace,
                  runtime.proof_ledger,
                  runtime.plan_progress,
                  worker_host
                )
              )
              |> Keyword.put(:lifecycle_event, fn event, attrs ->
                RunAudit.append(workspace, issue, event, attrs)

                send_codex_update(codex_update_recipient, issue, %{
                  event: :workflow_phase,
                  timestamp: DateTime.utc_now(),
                  phase: attrs[:phase],
                  status: attrs[:status],
                  revision: attrs[:revision],
                  verdict: attrs[:verdict]
                })
              end)

            planning_runner =
              Keyword.get(runtime.opts, :planning_lifecycle_runner, &PlanningLifecycle.run/6)

            task_branch_ensurer =
              Keyword.get(runtime.opts, :task_branch_ensurer, &TaskBranch.ensure/5)

            with {:ok, _thread_id} <- ThreadIdentity.pin(workspace, session.thread_id, worker_host),
                 {:ok, execution_plan} <-
                   planning_runner.(
                     session,
                     workspace,
                     issue,
                     task_contract,
                     Keyword.fetch!(runtime.opts, :workflow_profile),
                     planning_opts
                   ),
                 :ok <- record_execution_plan_approved(workspace, issue, session, execution_plan),
                 :ok <- set_goal_and_record(workspace, issue, session, task_contract, execution_plan),
                 {:ok, task_branch} <-
                   task_branch_ensurer.(
                     workspace,
                     issue,
                     execution_plan["workflow"],
                     get_in(execution_plan, ["candidate", "repository", "base_sha"]),
                     worker_host
                   ) do
              RunAudit.append(workspace, issue, :task_branch_ready, %{
                phase: "implementation",
                status: "completed",
                branch: task_branch,
                base_sha: get_in(execution_plan, ["candidate", "repository", "base_sha"])
              })

              Agent.update(runtime.proof_ledger, fn _planning_proofs -> %{} end)
              Agent.update(runtime.plan_progress, fn _planning_plan -> nil end)

              runtime = %{
                runtime
                | opts: Keyword.put(runtime.opts, :execution_plan, execution_plan)
              }

              result =
                do_run_codex_turns(
                  session,
                  workspace,
                  issue,
                  task_contract,
                  codex_update_recipient,
                  runtime,
                  {1, max_turns}
                )

              update_goal_for_result(session, workspace, issue, result)
            else
              {:error, reason} = error ->
                RunAudit.append(workspace, issue, :codex_goal_failed, %{
                  phase: "codex_goal",
                  status: "failed",
                  reason: reason,
                  thread_id: session.thread_id
                })

                error
            end
          after
            RunAudit.append(workspace, issue, :codex_app_server_stopping, %{phase: "codex_app_server", status: "stopping"})
            AppServer.stop_session(session)
          end

        {:error, reason} = error ->
          RunAudit.append(workspace, issue, :codex_app_server_failed, %{phase: "codex_app_server", status: "failed", reason: reason})
          error
      end
    after
      Agent.stop(proof_ledger)
      Agent.stop(plan_progress)
    end
  end

  defp record_execution_plan_approved(workspace, issue, session, execution_plan) do
    RunAudit.append(workspace, issue, :execution_plan_approved, %{
      phase: "planning",
      status: "completed",
      plan_digest: execution_plan["plan_digest"],
      workflow: execution_plan["workflow"],
      profile_digest: execution_plan["profile_digest"],
      thread_id: session.thread_id
    })

    :ok
  end

  defp set_goal_and_record(workspace, issue, session, task_contract, execution_plan) do
    with :ok <- AppServer.set_goal(session, goal_objective(issue, task_contract, execution_plan)) do
      RunAudit.append(workspace, issue, :codex_goal_set, %{
        phase: "codex_goal",
        status: "completed",
        goal_status: "active",
        plan_digest: execution_plan["plan_digest"],
        thread_id: session.thread_id
      })

      :ok
    end
  end

  defp start_codex_session(workspace, worker_host) do
    case ThreadIdentity.read(workspace, worker_host) do
      :missing ->
        AppServer.start_session(workspace,
          worker_host: worker_host,
          dynamic_tools: PlanningArtifact.candidate_tool_specs()
        )

      {:ok, thread_id} ->
        AppServer.start_session(workspace,
          worker_host: worker_host,
          thread_id: thread_id,
          dynamic_tools: PlanningArtifact.candidate_tool_specs()
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp update_goal_for_result(session, workspace, issue, result) do
    goal_status = goal_status_for_result(result)

    case AppServer.set_goal_status(session, goal_status) do
      :ok ->
        RunAudit.append(workspace, issue, :codex_goal_updated, %{
          phase: "codex_goal",
          status: "completed",
          goal_status: goal_status,
          thread_id: session.thread_id
        })

        result

      {:error, reason} ->
        RunAudit.append(workspace, issue, :codex_goal_failed, %{
          phase: "codex_goal",
          status: "failed",
          goal_status: goal_status,
          reason: reason,
          thread_id: session.thread_id
        })

        {:error, {:goal_state_update_failed, goal_status, reason}}
    end
  end

  defp goal_status_for_result({:ok, %{issue_active: false}}), do: "complete"
  defp goal_status_for_result({:ok, %{issue_routable: false}}), do: "complete"

  defp goal_status_for_result({:error, {reason, _details}})
       when reason in [:turn_input_required, :approval_required],
       do: "blocked"

  defp goal_status_for_result(_result), do: "active"

  defp do_run_codex_turns(
         app_session,
         workspace,
         issue,
         task_contract,
         codex_update_recipient,
         runtime,
         {turn_number, max_turns}
       ) do
    prompt = build_turn_prompt(issue, runtime.opts, turn_number, max_turns)
    RunAudit.append(workspace, issue, :codex_turn_started, %{phase: "codex_turn", status: "started", turn_number: turn_number})

    case AppServer.run_turn(
           app_session,
           prompt,
           issue,
           on_message:
             codex_message_handler(
               codex_update_recipient,
               issue,
               workspace,
               runtime.proof_ledger,
               runtime.plan_progress,
               runtime.worker_host
             )
         ) do
      {:ok, turn_session} ->
        Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")
        RunAudit.append(workspace, issue, :codex_turn_completed, %{phase: "codex_turn", status: "completed", session_id: turn_session[:session_id], turn_number: turn_number})

        handle_completed_turn(
          app_session,
          workspace,
          issue,
          task_contract,
          codex_update_recipient,
          runtime,
          {turn_number, max_turns}
        )

      {:error, reason} = error ->
        RunAudit.append(workspace, issue, :codex_turn_failed, %{phase: "codex_turn", status: "failed", reason: reason, turn_number: turn_number})
        error
    end
  end

  defp handle_completed_turn(
         app_session,
         workspace,
         issue,
         task_contract,
         codex_update_recipient,
         runtime,
         turn_numbers
       ) do
    case continue_with_issue?(issue, task_contract, runtime.issue_state_fetcher) do
      {:continue, refreshed_issue} ->
        handoff_result =
          finish_handoff(workspace, issue, refreshed_issue, task_contract, runtime, elem(turn_numbers, 0))

        handle_handoff_result(
          handoff_result,
          app_session,
          workspace,
          task_contract,
          codex_update_recipient,
          runtime,
          turn_numbers
        )

      {:done, refreshed_issue} ->
        finish_handoff(workspace, issue, refreshed_issue, task_contract, runtime, elem(turn_numbers, 0))

      {:error, reason} ->
        record_continuation_failure(workspace, issue, reason, elem(turn_numbers, 0))
    end
  end

  defp handle_handoff_result(
         {:continue, refreshed_issue},
         app_session,
         workspace,
         task_contract,
         codex_update_recipient,
         runtime,
         {turn_number, max_turns}
       )
       when turn_number < max_turns do
    Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

    RunAudit.append(workspace, refreshed_issue, :codex_turn_continuing, %{
      phase: "codex_turn",
      status: "continuing",
      reason: "handoff_evidence_pending",
      previous_turn_number: turn_number,
      turn_number: turn_number + 1,
      issue_state: refreshed_issue.state,
      issue_labels: Enum.join(refreshed_issue.labels, ",")
    })

    do_run_codex_turns(
      app_session,
      workspace,
      refreshed_issue,
      task_contract,
      codex_update_recipient,
      runtime,
      {turn_number + 1, max_turns}
    )
  end

  defp handle_handoff_result(
         {:continue, refreshed_issue},
         _app_session,
         workspace,
         _task_contract,
         _codex_update_recipient,
         _runtime,
         {turn_number, _max_turns}
       ) do
    Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")
    RunAudit.append(workspace, refreshed_issue, :codex_max_turns_reached, %{phase: "codex_turn", status: "max_turns_reached", turn_number: turn_number})

    {:ok, completion_info(refreshed_issue, :max_turns_reached)}
  end

  defp handle_handoff_result(
         result,
         _app_session,
         _workspace,
         _task_contract,
         _codex_update_recipient,
         _runtime,
         _turn_numbers
       ),
       do: result

  defp record_continuation_failure(workspace, issue, reason, turn_number) do
    RunAudit.append(workspace, issue, :codex_continuation_check_failed, %{
      phase: "codex_turn",
      status: "failed",
      reason: reason,
      turn_number: turn_number
    })

    {:error, reason}
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns),
    do: PromptBuilder.build_execution_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - Inspect the native plan and resume the earliest incomplete approved phase. Do not add, remove, rename, reorder, or skip phases.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - First check whether the implementation is already complete but `.symphony/completion-evidence.json` is missing or stale; if so, refresh that artifact before doing more implementation.
    - If a PR, commit, or proof result already exists, verify only the missing handoff facts instead of rerunning broad setup, research, or full test gates.
    - Before leaving the active workflow, atomically refresh `.symphony/completion-evidence.json` with exact proof coverage and the repository PR URL required by the original prompt.
    - Do not create the completed-work Linear handoff comment or move the issue to the configured handoff state; Symphony owns those external writes after validation.
    - Record the reason for the extra turn in `.symphony/run-audit.md`, including whether it was missing handoff, missing state transition, rework, or a real blocker.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp goal_objective(issue, task_contract, execution_plan) do
    issue
    |> raw_goal_objective(task_contract, execution_plan)
    |> String.slice(0, 4_000)
  end

  defp raw_goal_objective(%Issue{identifier: identifier}, task_contract, execution_plan) do
    """
    Deliver Linear #{identifier} under contract #{task_contract.digest} and workflow
    #{execution_plan["profile_digest"]} using approved execution plan #{execution_plan["plan_digest"]}. Preserve scope
    and produce Symphony-validated proof and PR handoff.
    """
    |> String.trim()
  end

  defp continue_with_issue?(%Issue{} = issue, issue_state_fetcher) do
    continue_with_issue?(issue, nil, issue_state_fetcher)
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, contract, issue_state_fetcher)
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          continue_with_contract(refreshed_issue, contract)
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _contract, _issue_state_fetcher), do: {:done, issue}

  defp continue_with_contract(refreshed_issue, nil), do: {:continue, refreshed_issue}

  defp continue_with_contract(refreshed_issue, %TaskContract{} = contract) do
    compare_plan_revision(refreshed_issue, contract)
  end

  defp compare_plan_revision(refreshed_issue, contract) do
    case TaskContract.from_issue(refreshed_issue) do
      {:ok, %{digest: digest}} when digest == contract.digest ->
        {:continue, refreshed_issue}

      {:ok, %{digest: digest}} ->
        {:error, {:plan_drift, contract.digest, digest}}

      {:error, errors} ->
        {:error, {:invalid_task_contract, errors}}
    end
  end

  defp task_contract_for_issue(%Issue{} = issue, opts) do
    with {:ok, current} <- TaskContract.from_issue(issue) do
      case Keyword.get(opts, :task_contract) do
        %TaskContract{digest: digest} when digest == current.digest -> {:ok, current}
        %TaskContract{digest: digest} -> {:error, {:plan_drift, digest, current.digest}}
        nil -> {:ok, current}
      end
    end
  end

  defp validate_handoff(workspace, issue, contract, proofs, opts) do
    validator = Keyword.get(opts, :completion_evidence_validator, &CompletionEvidence.validate/5)
    validator_opts = Keyword.delete(opts, :completion_evidence_validator)

    case validator.(workspace, issue, contract, proofs, validator_opts) do
      {:ok, evidence} -> {:ok, evidence}
      {:error, reason} -> {:error, {:handoff_evidence_invalid, reason}}
    end
  end

  defp finish_handoff(workspace, issue, refreshed_issue, task_contract, runtime, turn_number) do
    opts =
      [
        worker_host: runtime.worker_host,
        thread_id: Map.get(runtime, :thread_id),
        execution_plan: Keyword.get(runtime.opts, :execution_plan)
      ] ++
        Keyword.take(runtime.opts, [:completion_evidence_validator, :handoff_publisher, :handoff_state])

    execution_plan = Keyword.get(runtime.opts, :execution_plan)
    native_plan = Agent.get(runtime.plan_progress, & &1)

    case validate_execution_progress(execution_plan, native_plan) do
      :ok ->
        handoff_after_turn(
          workspace,
          issue,
          refreshed_issue,
          task_contract,
          Agent.get(runtime.proof_ledger, & &1),
          opts,
          turn_number
        )

      {:error, reason} ->
        handle_execution_progress_pending(
          workspace,
          issue,
          refreshed_issue,
          reason,
          turn_number
        )
    end
  end

  defp validate_execution_progress(
         %{"candidate" => %{"ordered_steps" => [_phase | _]}} = execution_plan,
         native_plan
       ) do
    ExecutionPlanProgress.validate(execution_plan, native_plan)
  end

  defp validate_execution_progress(_execution_plan, _native_plan), do: :ok

  defp handle_execution_progress_pending(workspace, issue, refreshed_issue, reason, turn_number) do
    RunAudit.append(workspace, issue, :execution_plan_progress_pending, %{
      phase: "implementation",
      status: "pending",
      reason: reason,
      turn_number: turn_number
    })

    if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue),
      do: {:continue, refreshed_issue},
      else: {:error, {:execution_plan_progress_invalid, reason}}
  end

  defp handoff_after_turn(workspace, issue, refreshed_issue, task_contract, proofs, opts, turn_number) do
    handoff_state =
      Keyword.get_lazy(opts, :handoff_state, fn -> Config.settings!().tracker.handoff_state end)

    if active_issue_state?(refreshed_issue.state) or
         same_issue_state?(refreshed_issue.state, handoff_state) do
      case compare_plan_revision(refreshed_issue, task_contract) do
        {:continue, current_issue} ->
          validate_and_publish_handoff(
            workspace,
            issue,
            current_issue,
            task_contract,
            proofs,
            opts,
            turn_number
          )

        {:error, _reason} = error ->
          append_handoff_audit(workspace, issue, :handoff_publish_rejected, task_contract, opts, %{
            status: "failed",
            evidence_result: "rejected",
            transition_target: handoff_state,
            result: "failed",
            retry: false,
            ambiguous: false
          })

          error
      end
    else
      reason = {:handoff_state_advanced_before_publish, refreshed_issue.state}

      append_handoff_audit(workspace, issue, :handoff_publish_rejected, task_contract, opts, %{
        status: "failed",
        evidence_result: "rejected",
        issue_state: refreshed_issue.state,
        transition_target: handoff_state,
        result: "failed",
        retry: false,
        ambiguous: false
      })

      {:error, reason}
    end
  end

  defp validate_and_publish_handoff(
         workspace,
         issue,
         refreshed_issue,
         task_contract,
         proofs,
         opts,
         turn_number
       ) do
    case validate_handoff(
           workspace,
           refreshed_issue,
           task_contract,
           proofs,
           opts
         ) do
      {:ok, evidence} ->
        publish_handoff(workspace, issue, refreshed_issue, task_contract, evidence, opts, turn_number)

      {:error, {:handoff_evidence_invalid, :completion_evidence_missing}} = error ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          append_handoff_audit(workspace, issue, :handoff_evidence_pending, task_contract, opts, %{
            status: "pending",
            evidence_result: "pending",
            result: "pending",
            retry: true,
            ambiguous: false
          })

          {:continue, refreshed_issue}
        else
          append_handoff_audit(workspace, issue, :handoff_evidence_rejected, task_contract, opts, %{
            status: "failed",
            evidence_result: "rejected",
            transition_target: Keyword.get(opts, :handoff_state),
            result: "failed",
            retry: false,
            ambiguous: false
          })

          error
        end

      {:error, _reason} = error ->
        append_handoff_audit(workspace, issue, :handoff_evidence_rejected, task_contract, opts, %{
          status: "failed",
          evidence_result: "rejected",
          result: "failed",
          retry: true,
          ambiguous: false
        })

        error
    end
  end

  defp publish_handoff(workspace, issue, refreshed_issue, task_contract, evidence, opts, turn_number) do
    publisher = Keyword.get(opts, :handoff_publisher, &HandoffPublisher.publish/4)

    handoff_state =
      Keyword.get_lazy(opts, :handoff_state, fn -> Config.settings!().tracker.handoff_state end)

    publisher_opts =
      [
        handoff_state: handoff_state,
        event_sink: handoff_event_sink(workspace, issue)
      ]
      |> maybe_put_thread_id(Keyword.get(opts, :thread_id))

    case publisher.(refreshed_issue, task_contract, evidence, publisher_opts) do
      {:ok, publication} ->
        record_published_handoff(
          workspace,
          issue,
          refreshed_issue,
          task_contract,
          evidence,
          publication,
          turn_number,
          opts
        )

      {:error, reason} = error ->
        append_handoff_audit(workspace, issue, :handoff_publish_failed, task_contract, opts, %{
          status: "failed",
          evidence_result: "publish_failed",
          transition_target: handoff_state,
          artifact_digest: evidence.artifact_digest,
          result: "failed",
          retry: true,
          ambiguous: handoff_ambiguous?(reason)
        })

        error

      other ->
        append_handoff_audit(workspace, issue, :handoff_publish_failed, task_contract, opts, %{
          status: "failed",
          evidence_result: "publish_failed",
          transition_target: handoff_state,
          artifact_digest: evidence.artifact_digest,
          result: "failed",
          retry: true,
          ambiguous: false
        })

        {:error, {:handoff_publish_failed, other}}
    end
  end

  defp record_published_handoff(
         workspace,
         issue,
         refreshed_issue,
         task_contract,
         evidence,
         publication,
         turn_number,
         opts
       ) do
    RunAudit.append(workspace, issue, :codex_continuation_check_completed, %{
      phase: "codex_turn",
      status: "done",
      turn_number: turn_number
    })

    append_handoff_audit(workspace, issue, :handoff_evidence_validated, task_contract, opts, %{
      status: "completed",
      evidence_result: "validated",
      artifact_digest: evidence.artifact_digest,
      result: "completed",
      retry: false,
      ambiguous: false
    })

    append_handoff_audit(workspace, issue, :handoff_published, task_contract, opts, %{
      status: "completed",
      evidence_result: "published",
      comment_id: publication.comment_id,
      issue_state: publication.issue_state,
      transition_target: publication.issue_state,
      artifact_digest: evidence.artifact_digest,
      result: "completed",
      retry: false,
      ambiguous: false
    })

    {:ok,
     %{refreshed_issue | state: publication.issue_state}
     |> completion_info(:done)
     |> Map.merge(%{
       pull_request_url: evidence.pull_request_url,
       handoff_comment_id: publication.comment_id,
       completion_artifact_digest: evidence.artifact_digest
     })}
  end

  defp record_observed_proof(proof_ledger, event_id, proof, workspace, worker_host) do
    head_sha =
      case RepositoryFingerprint.head(workspace, worker_host) do
        {:ok, sha} -> sha
        {:error, _reason} -> nil
      end

    Agent.update(proof_ledger, fn proofs ->
      if map_size(proofs) < 256 do
        Map.put(proofs, event_id, %{
          exit_code: proof.exit_code,
          command: proof.command,
          sequence: map_size(proofs) + 1,
          head_sha: head_sha
        })
      else
        Map.put(proofs, "__proof_limit_exceeded__", %{exit_code: -1})
      end
    end)
  end

  defp completion_info(%Issue{} = issue, continuation) when continuation in [:done, :max_turns_reached] do
    %{
      continuation: continuation,
      issue_state: issue.state,
      issue_active: active_issue_state?(issue.state),
      issue_routable: issue_routable?(issue),
      issue_labels: issue.labels
    }
  end

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp same_issue_state?(left, right) when is_binary(left) and is_binary(right) do
    normalize_issue_state(left) == normalize_issue_state(right)
  end

  defp same_issue_state?(_left, _right), do: false

  defp handoff_event_sink(workspace, issue) do
    fn event, attrs -> RunAudit.append_handoff_event(workspace, issue, event, attrs) end
  end

  defp append_handoff_audit(workspace, issue, event, task_contract, opts, attrs) do
    common = %{
      phase: "handoff",
      plan_digest: task_contract.digest,
      thread_id: Keyword.get(opts, :thread_id)
    }

    RunAudit.append_handoff_event(workspace, issue, event, Map.merge(common, attrs))
  end

  defp maybe_put_thread_id(opts, thread_id) when is_binary(thread_id) and thread_id != "" do
    Keyword.put(opts, :thread_id, thread_id)
  end

  defp maybe_put_thread_id(opts, _thread_id), do: opts

  defp handoff_ambiguous?({reason, _one, _two})
       when reason in [
              :handoff_comment_unverified,
              :handoff_comment_read_failed,
              :handoff_state_transition_failed,
              :handoff_state_transition_read_failed,
              :handoff_state_transition_unverified
            ],
       do: true

  defp handoff_ambiguous?({reason, _rest})
       when reason in [:handoff_comment_collision, :handoff_comment_read_failed, :handoff_state_read_failed],
       do: true

  defp handoff_ambiguous?(_reason), do: false

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
