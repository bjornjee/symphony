defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Codex.ThreadIdentity
  alias SymphonyElixir.CompletionEvidence
  alias SymphonyElixir.Config
  alias SymphonyElixir.DeliveryControl
  alias SymphonyElixir.ExecutionControl
  alias SymphonyElixir.ExecutionLedger
  alias SymphonyElixir.ExecutionManifest
  alias SymphonyElixir.ExecutionPlanProgress
  alias SymphonyElixir.HandoffPublisher
  alias SymphonyElixir.HumanReviewBlocker
  alias SymphonyElixir.InstructionAuthority
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
  @spec implementation_sandbox_policy_for_test(Path.t(), map()) :: map()
  def implementation_sandbox_policy_for_test(workspace, execution_plan) do
    implementation_sandbox_policy(workspace, execution_plan)
  end

  @doc false
  @spec implementation_command_approval_for_test(Path.t(), map()) :: boolean()
  def implementation_command_approval_for_test(workspace, payload) do
    implementation_command_approval?(workspace, payload)
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

  defp send_worker_capability_info(recipient, %Issue{id: issue_id}, diagnostics)
       when is_binary(issue_id) and is_pid(recipient) and is_map(diagnostics) do
    send(recipient, {:worker_runtime_info, issue_id, %{capability_diagnostics: diagnostics}})
    :ok
  end

  defp send_worker_capability_info(_recipient, _issue, _diagnostics), do: :ok

  defp record_capability_diagnostics(workspace, issue, diagnostics) do
    browser_path = diagnostics.browser_path

    RunAudit.append(workspace, issue, :capability_diagnostics_resolved, %{
      phase: "capability_diagnostics",
      status: "completed",
      browser_path: browser_path.selected,
      browser_provenance: browser_path.provenance,
      browser_code: browser_path.code,
      browser_action: browser_path.action,
      browser_usable: diagnostics.browser.usable,
      playwright_usable: diagnostics.playwright.usable,
      computer_use_usable: diagnostics.computer_use.usable,
      computer_use_app_count: diagnostics.computer_use.app_count
    })
  end

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
            capability_diagnostics_resolver =
              Keyword.get(
                runtime.opts,
                :capability_diagnostics_resolver,
                &AppServer.capability_diagnostics/1
              )

            {:ok, capability_diagnostics} = capability_diagnostics_resolver.(session)
            record_capability_diagnostics(workspace, issue, capability_diagnostics)
            send_worker_capability_info(codex_update_recipient, issue, capability_diagnostics)

            runtime =
              runtime
              |> Map.put(:thread_id, session.thread_id)
              |> Map.update!(:opts, &Keyword.put(&1, :capability_diagnostics, capability_diagnostics))

            with {:ok, instruction_authority} <-
                   InstructionAuthority.capture(session.instruction_sources, worker_host) do
              planning_opts =
                runtime.opts
                |> Keyword.put(:worker_host, worker_host)
                |> Keyword.put(:instruction_authority, instruction_authority)
                |> Keyword.put(:pin_primary_thread, fn ->
                  case ThreadIdentity.pin(workspace, session.thread_id, worker_host) do
                    {:ok, _thread_id} -> :ok
                    {:error, _reason} = error -> error
                  end
                end)
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

              with {:ok, execution_plan} <-
                     execution_plan_for_run(
                       planning_runner,
                       session,
                       workspace,
                       issue,
                       task_contract,
                       Keyword.fetch!(runtime.opts, :workflow_profile),
                       instruction_authority,
                       planning_opts
                     ),
                   :ok <- pin_thread_before_goal(execution_plan, workspace, session, worker_host),
                   ledger_key <- execution_ledger_key(execution_plan, issue),
                   :ok <-
                     persist_execution_authority(
                       ledger_key,
                       execution_plan,
                       instruction_authority,
                       session,
                       issue
                     ),
                   :ok <- record_execution_plan_approved(workspace, issue, session, execution_plan),
                   :ok <- set_goal_and_record(workspace, issue, session, task_contract, execution_plan),
                   {:ok, _thread_id} <- ThreadIdentity.pin(workspace, session.thread_id, worker_host),
                   {:ok, task_branch} <-
                     task_branch_ensurer.(
                       workspace,
                       issue,
                       execution_plan["workflow"],
                       execution_plan_base_sha(execution_plan),
                       worker_host
                     ) do
                RunAudit.append(workspace, issue, :task_branch_ready, %{
                  phase: "implementation",
                  status: "completed",
                  branch: task_branch,
                  base_sha: execution_plan_base_sha(execution_plan)
                })

                Agent.update(runtime.proof_ledger, fn _planning_proofs -> %{} end)
                Agent.update(runtime.plan_progress, fn _planning_plan -> nil end)

                runtime = %{
                  runtime
                  | opts:
                      runtime.opts
                      |> Keyword.put(:execution_plan, execution_plan)
                      |> Keyword.put(:execution_ledger_key, ledger_key)
                      |> Keyword.put(:instruction_authority, instruction_authority)
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
      phase: if(execution_plan["execution_mode"] == "simple", do: "classification", else: "planning"),
      status: "completed",
      execution_mode: execution_plan["execution_mode"] || "planned",
      plan_digest: execution_plan["plan_digest"],
      workflow: execution_plan["workflow"],
      profile_digest: execution_plan["profile_digest"],
      thread_id: session.thread_id
    })

    :ok
  end

  defp execution_plan_base_sha(%{"repository" => %{"base_sha" => base_sha}}), do: base_sha

  defp execution_plan_base_sha(execution_plan),
    do: get_in(execution_plan, ["candidate", "repository", "base_sha"])

  defp pin_thread_before_goal(%{"execution_mode" => "simple"}, _workspace, _session, _worker_host),
    do: :ok

  defp pin_thread_before_goal(_execution_plan, workspace, session, worker_host) do
    case ThreadIdentity.pin(workspace, session.thread_id, worker_host) do
      {:ok, _thread_id} -> :ok
      {:error, _reason} = error -> error
    end
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
          dynamic_tools:
            PlanningArtifact.candidate_tool_specs() ++
              ExecutionControl.tool_specs() ++ DeliveryControl.tool_specs()
        )

      {:ok, thread_id} ->
        AppServer.start_session(workspace,
          worker_host: worker_host,
          thread_id: thread_id,
          dynamic_tools:
            PlanningArtifact.candidate_tool_specs() ++
              ExecutionControl.tool_specs() ++ DeliveryControl.tool_specs()
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

  defp goal_status_for_result({:ok, %{outcome: :human_review_required}}), do: "blocked"
  defp goal_status_for_result({:ok, %{issue_active: false}}), do: "complete"
  defp goal_status_for_result({:ok, %{issue_routable: false}}), do: "complete"

  defp goal_status_for_result({:error, {reason, _details}})
       when reason in [:turn_input_required, :approval_required, :instruction_drift_human_review],
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
    case revalidate_authority_and_proof_budget(
           app_session,
           workspace,
           issue,
           task_contract,
           runtime
         ) do
      :ok ->
        prompt = build_turn_prompt(issue, runtime.opts, turn_number, max_turns)
        RunAudit.append(workspace, issue, :codex_turn_started, %{phase: "codex_turn", status: "started", turn_number: turn_number})

        case AppServer.run_turn(
               app_session,
               prompt,
               issue,
               approval_policy: "on-request",
               command_approval_authorizer: &implementation_command_approval?(workspace, &1),
               sandbox_policy:
                 implementation_sandbox_policy(
                   workspace,
                   Keyword.fetch!(runtime.opts, :execution_plan)
                 ),
               tool_executor:
                 execution_tool_executor(
                   app_session,
                   runtime,
                   workspace,
                   issue,
                   task_contract
                 ),
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

            handle_completed_or_exhausted_turn(
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

            handle_failed_or_exhausted_turn(
              workspace,
              issue,
              task_contract,
              runtime,
              error
            )
        end

      {:blocked, completion_info} ->
        {:ok, completion_info}

      {:error, :instruction_drift} ->
        handle_instruction_drift(workspace, issue, task_contract, runtime)

      {:error, _reason} = error ->
        error
    end
  end

  defp revalidate_authority_and_proof_budget(app_session, workspace, issue, contract, runtime) do
    with :ok <-
           revalidate_execution_authority(
             app_session,
             workspace,
             issue,
             contract,
             runtime
           ) do
      block_exhausted_proof(workspace, issue, contract, runtime)
    end
  end

  defp handle_completed_or_exhausted_turn(
         app_session,
         workspace,
         issue,
         task_contract,
         codex_update_recipient,
         runtime,
         turn_numbers
       ) do
    case block_exhausted_proof(workspace, issue, task_contract, runtime) do
      :ok ->
        handle_completed_turn(
          app_session,
          workspace,
          issue,
          task_contract,
          codex_update_recipient,
          runtime,
          turn_numbers
        )

      {:blocked, completion_info} ->
        {:ok, completion_info}

      {:error, _reason} = error ->
        error
    end
  end

  defp handle_failed_or_exhausted_turn(workspace, issue, contract, runtime, turn_error) do
    case block_exhausted_proof(workspace, issue, contract, runtime) do
      :ok -> turn_error
      {:blocked, completion_info} -> {:ok, completion_info}
      {:error, _reason} = blocker_error -> blocker_error
    end
  end

  defp block_exhausted_proof(workspace, issue, contract, runtime) do
    plan = Keyword.fetch!(runtime.opts, :execution_plan)
    key = Keyword.fetch!(runtime.opts, :execution_ledger_key)

    case ExecutionControl.block_on_exhausted_proof(plan, key, issue, contract) do
      :none ->
        :ok

      {:ok, completion_info} ->
        RunAudit.append(workspace, issue, :execution_proof_exhausted, %{
          phase: "proof",
          status: "blocked",
          proof_id: completion_info.blocker_proof_id,
          receipt_digest: completion_info.blocker_receipt_digest,
          comment_id: completion_info.blocker_comment_id,
          issue_state: completion_info.issue_state
        })

        {:blocked, completion_info}

      {:error, _reason} = error ->
        error
    end
  end

  defp handle_instruction_drift(workspace, issue, contract, runtime) do
    plan = Keyword.fetch!(runtime.opts, :execution_plan)

    with {:ok, repository} <- RepositoryFingerprint.capture(workspace, runtime.worker_host) do
      if repository.clean and repository.base_sha == execution_plan_base_sha(plan),
        do: {:error, :instruction_drift_replan_required},
        else: publish_instruction_drift_blocker(issue, contract, plan["plan_digest"])
    end
  end

  defp execution_plan_for_run(
         planning_runner,
         session,
         workspace,
         issue,
         contract,
         profile,
         instruction_authority,
         planning_opts
       ) do
    worker_host = Keyword.get(planning_opts, :worker_host)

    with {:ok, repository} <- RepositoryFingerprint.capture(workspace, worker_host),
         {:ok, registered} <-
           registered_execution_plan(
             repository,
             issue,
             contract,
             profile,
             session,
             instruction_authority
           ) do
      case registered do
        :missing ->
          planning_runner.(session, workspace, issue, contract, profile, planning_opts)

        plan when is_map(plan) ->
          {:ok, plan}
      end
    else
      {:error, {:instruction_drift_with_changes, old_plan_digest}} ->
        publish_instruction_drift_blocker(issue, contract, old_plan_digest)

      {:error, _reason} = error ->
        error
    end
  end

  # This is one bounded decision table over immutable authority receipts.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp registered_execution_plan(repository, issue, contract, profile, session, authority) do
    key = authority_registry_key(repository.origin, issue.id)

    with {:ok, receipts} <- ExecutionLedger.list(key, "execution-plan") do
      valid = Enum.filter(receipts, &valid_registered_plan?/1)

      exact =
        Enum.filter(valid, fn receipt ->
          plan = receipt["plan"]

          plan["contract_digest"] == contract.digest and
            plan["profile_digest"] == profile.digest and
            plan["primary_thread_id"] == session.thread_id and
            plan["instruction_digest"] == authority.digest and
            execution_plan_origin(plan) == repository.origin
        end)

      cond do
        length(valid) != length(receipts) ->
          {:error, :registered_execution_plan_invalid}

        length(exact) == 1 ->
          {:ok, hd(exact)["plan"]}

        length(exact) > 1 ->
          {:error, :multiple_registered_execution_plans}

        valid == [] ->
          {:ok, :missing}

        Enum.any?(valid, &(&1["plan"]["contract_digest"] != contract.digest)) ->
          {:error, :registered_execution_plan_contract_drift}

        repository.clean and Enum.any?(valid, &(execution_plan_base_sha(&1["plan"]) == repository.base_sha)) ->
          {:ok, :missing}

        true ->
          old_plan = List.first(valid)["plan"]
          {:error, {:instruction_drift_with_changes, old_plan["plan_digest"]}}
      end
    end
  end

  defp valid_registered_plan?(%{"plan" => %{"plan_digest" => digest} = plan, "instruction_paths" => paths})
       when is_binary(digest) and is_list(paths) do
    digest == PlanningArtifact.digest(Map.delete(plan, "plan_digest"))
  end

  defp valid_registered_plan?(_receipt), do: false

  defp persist_execution_authority(key, plan, instruction_authority, session, issue) do
    receipt = %{
      "plan_digest" => plan["plan_digest"],
      "instruction_digest" => instruction_authority.digest,
      "instruction_paths" => instruction_authority.paths,
      "profile_digest" => plan["profile_digest"],
      "contract_digest" => plan["contract_digest"],
      "primary_thread_id" => session.thread_id
    }

    with :ok <-
           persist_receipt(
             key,
             "authority",
             "pinned",
             receipt,
             :execution_authority_receipt_drift
           ) do
      persist_receipt(
        authority_registry_key(execution_plan_origin(plan), issue.id),
        "execution-plan",
        plan["authority_digest"] || plan["plan_digest"],
        %{"plan" => plan, "instruction_paths" => instruction_authority.paths},
        :registered_execution_plan_drift
      )
    end
  end

  defp persist_receipt(key, kind, id, receipt, drift_error) do
    case ExecutionLedger.create(key, kind, id, receipt) do
      {:ok, _persisted} ->
        :ok

      :exists ->
        validate_existing_receipt(key, kind, id, receipt, drift_error)

      {:error, reason} ->
        {:error, {:execution_authority_receipt_failed, reason}}
    end
  end

  defp validate_existing_receipt(key, kind, id, receipt, drift_error) do
    case ExecutionLedger.read(key, kind, id) do
      {:ok, existing} ->
        if Map.drop(existing, ["receipt_digest"]) == receipt,
          do: :ok,
          else: {:error, drift_error}

      other ->
        {:error, {:execution_authority_receipt_invalid, other}}
    end
  end

  defp publish_instruction_drift_blocker(issue, contract, plan_digest) do
    body =
      "## Agent Blocked\n\nInstruction authority changed after implementation changes existed. " <>
        "Symphony will not reinterpret those changes under different doctrine. Human Review is required.\n\n" <>
        "<!-- symphony-instruction-drift:v1 plan=#{plan_digest} -->"

    case HumanReviewBlocker.publish(
           issue,
           [contract.digest, plan_digest, "instruction-drift"],
           body
         ) do
      {:ok, comment_id} -> {:error, {:instruction_drift_human_review, comment_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authority_registry_key(origin, issue_id),
    do: ExecutionLedger.key(origin, issue_id, "execution-authority")

  defp revalidate_execution_authority(session, workspace, issue, contract, runtime) do
    plan = Keyword.fetch!(runtime.opts, :execution_plan)
    authority = Keyword.fetch!(runtime.opts, :instruction_authority)

    with :ok <- InstructionAuthority.revalidate(authority),
         true <- plan["instruction_digest"] == authority.digest || {:error, :implementation_instruction_drift},
         true <- plan["primary_thread_id"] == session.thread_id || {:error, :implementation_thread_drift},
         {:ok, [%Issue{} = refreshed | _]} <- runtime.issue_state_fetcher.([issue.id]),
         {:ok, refreshed_contract} <- TaskContract.from_issue(refreshed),
         true <- refreshed_contract.digest == contract.digest || {:error, :implementation_contract_drift},
         true <- plan["contract_digest"] == refreshed_contract.digest || {:error, :implementation_plan_contract_drift},
         {:ok, profile} <- WorkflowProfile.select(refreshed_contract),
         true <- profile.digest == plan["profile_digest"] || {:error, :implementation_profile_drift},
         true <- plan["plan_digest"] == PlanningArtifact.digest(Map.delete(plan, "plan_digest")) || {:error, :implementation_plan_digest_drift},
         {:ok, repository} <- RepositoryFingerprint.capture(workspace, runtime.worker_host),
         true <- repository.origin == execution_plan_origin(plan) || {:error, :implementation_repository_drift} do
      TaskBranch.validate(
        workspace,
        issue,
        plan["workflow"],
        execution_plan_base_sha(plan),
        runtime.worker_host
      )
    end
  end

  defp execution_plan_origin(%{"candidate" => %{"repository" => %{"origin" => origin}}}), do: origin
  defp execution_plan_origin(%{"repository" => %{"origin" => origin}}), do: origin

  defp implementation_sandbox_policy(workspace, execution_plan) do
    protected_roots =
      execution_plan
      |> execution_plan_affected_paths()
      |> Enum.filter(&repository_codex_path?/1)
      |> Enum.map(&Path.dirname/1)
      |> Enum.map(&Path.join(workspace, &1))

    %{
      "type" => "workspaceWrite",
      "writableRoots" => Enum.uniq([workspace | protected_roots]),
      "networkAccess" => false
    }
  end

  defp execution_plan_affected_paths(%{"candidate" => %{"affected_paths" => paths}}) when is_list(paths), do: paths
  defp execution_plan_affected_paths(%{"affected_paths" => paths}) when is_list(paths), do: paths
  defp execution_plan_affected_paths(_execution_plan), do: []

  defp repository_codex_path?(path) when is_binary(path),
    do: path == ".codex" or String.starts_with?(path, ".codex/")

  defp repository_codex_path?(_path), do: false

  defp implementation_command_approval?(workspace, %{
         "params" =>
           %{
             "command" => command,
             "cwd" => cwd
           } = params
       })
       when is_binary(workspace) and is_binary(command) and is_binary(cwd) do
    Path.expand(cwd) == Path.expand(workspace) and
      is_nil(params["additionalPermissions"]) and
      is_nil(params["networkApprovalContext"]) and
      empty_approval_amendments?(params["proposedNetworkPolicyAmendments"]) and
      conventional_commit_command?(command)
  end

  defp implementation_command_approval?(_workspace, _payload), do: false

  defp empty_approval_amendments?(nil), do: true
  defp empty_approval_amendments?([]), do: true
  defp empty_approval_amendments?(_amendments), do: false

  defp conventional_commit_command?(command) do
    Regex.match?(
      ~r/\Agit commit -m (?:(?:"(?:feat|fix|refactor|docs|test|chore|perf|ci): [A-Za-z0-9][A-Za-z0-9 ._\/:\-]{0,62}")|(?:'(?:feat|fix|refactor|docs|test|chore|perf|ci): [A-Za-z0-9][A-Za-z0-9 ._\/:\-]{0,62}'))\z/,
      command
    )
  end

  defp execution_tool_executor(app_session, runtime, workspace, issue, contract) do
    plan = Keyword.fetch!(runtime.opts, :execution_plan)
    key = Keyword.fetch!(runtime.opts, :execution_ledger_key)

    fn tool, arguments ->
      result =
        if tool in ["request_implementation_review", "publish_pull_request"] do
          DeliveryControl.execute_tool(
            workspace,
            issue,
            contract,
            plan,
            key,
            tool,
            arguments,
            Keyword.put(runtime.opts, :worker_host, runtime.worker_host)
          )
        else
          ExecutionControl.execute_tool(
            plan,
            key,
            workspace,
            tool,
            arguments,
            worker_host: runtime.worker_host,
            command_executor: fn directory, command, command_opts ->
              AppServer.run_command(app_session, directory, command, command_opts)
            end
          )
          |> dynamic_tool_result()
        end

      record_execution_tool_event(workspace, issue, tool, arguments, result)
      result
    end
  end

  defp record_execution_tool_event(workspace, issue, tool, arguments, result) do
    payload = decode_dynamic_tool_output(result)

    attrs = %{
      phase: execution_tool_phase(tool),
      status: if(result["success"], do: "completed", else: "failed"),
      tool: tool,
      phase_id: arguments["phase_id"],
      proof_id: arguments["proof_id"],
      receipt_digest: payload["receipt_digest"],
      verdict: payload["verdict"],
      proof_role: payload["role"],
      proof_passed: payload["passed"],
      repository_head_sha: payload["head_sha"] || payload["repository_head_sha"],
      pull_request_url: payload["pull_request_url"]
    }

    RunAudit.append(workspace, issue, execution_tool_event(tool), attrs)
  end

  defp decode_dynamic_tool_output(%{"output" => output}) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, payload} when is_map(payload) -> payload
      _ -> %{}
    end
  end

  defp decode_dynamic_tool_output(_result), do: %{}

  defp execution_tool_event("run_plan_proof"), do: :execution_proof_recorded
  defp execution_tool_event("submit_fix_diagnosis"), do: :fix_diagnosis_recorded
  defp execution_tool_event("complete_execution_phase"), do: :execution_phase_completed
  defp execution_tool_event("request_implementation_review"), do: :implementation_review_recorded
  defp execution_tool_event("publish_pull_request"), do: :pull_request_published
  defp execution_tool_event(_tool), do: :execution_tool_rejected

  defp execution_tool_phase("run_plan_proof"), do: "proof"
  defp execution_tool_phase("submit_fix_diagnosis"), do: "diagnosis"
  defp execution_tool_phase("complete_execution_phase"), do: "implementation"
  defp execution_tool_phase("request_implementation_review"), do: "review"
  defp execution_tool_phase("publish_pull_request"), do: "publication"
  defp execution_tool_phase(_tool), do: "implementation"

  defp dynamic_tool_result({:ok, payload}) do
    output = Jason.encode!(payload, pretty: true)
    %{"success" => true, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  defp dynamic_tool_result({:error, reason}) do
    output = inspect(reason)
    %{"success" => false, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  defp execution_ledger_key(execution_plan, issue) do
    origin =
      get_in(execution_plan, ["candidate", "repository", "origin"]) ||
        get_in(execution_plan, ["repository", "origin"])

    ExecutionLedger.key(origin, issue.id, execution_plan["plan_digest"])
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
    - Inspect engine receipts and resume the earliest incomplete approved phase; do not rerun valid proof or phase receipts.
    - A failed proof receipt is not a valid proof receipt. When its phase is still incomplete and attempts remain, call `run_plan_proof` once to observe the current engine behavior; do not assume a prior engine failure still applies after Symphony resumed the run.
    - If a PR, commit, or proof result already exists, verify only the missing handoff facts instead of rerunning broad setup, research, or full test gates.
    - After the final commit, rerun final proof, request implementation review when required, and call `publish_pull_request`; Symphony generates completion evidence.
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
    #{execution_plan["profile_digest"]} under instructions #{execution_plan["instruction_digest"]}
    using approved execution plan #{execution_plan["plan_digest"]}. Preserve scope
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
        execution_plan: Keyword.get(runtime.opts, :execution_plan),
        execution_ledger_key: Keyword.get(runtime.opts, :execution_ledger_key)
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
