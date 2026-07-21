defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Codex.ThreadIdentity
  alias SymphonyElixir.{Config, ExecutionManifest, PromptBuilder, RunAudit, Tracker, Workspace}
  alias SymphonyElixir.Linear.{Issue, TaskContract}

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

  @spec run(Issue.t(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    case task_contract_for_issue(issue, opts) do
      {:ok, task_contract} ->
        opts = Keyword.put(opts, :task_contract, task_contract)
        # The orchestrator owns host retries so one worker lifetime never hops machines.
        worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

        Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} plan_digest=#{task_contract.digest}")

        case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
            raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
        end

      {:error, errors} when is_list(errors) ->
        message = Enum.join(errors, "; ")
        Logger.warning("Task contract invalid for #{issue_context(issue)}: #{message}")
        raise RuntimeError, "Task contract invalid for #{issue_context(issue)}: #{message}"

      {:error, reason} ->
        Logger.warning("Task contract rejected for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Task contract rejected for #{issue_context(issue)}: #{inspect(reason)}"
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

  defp codex_message_handler(recipient, issue, workspace) do
    fn message ->
      RunAudit.append_codex_update(workspace, issue, message)
      send_codex_update(recipient, issue, message)
    end
  end

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

    RunAudit.append(workspace, issue, :codex_app_server_starting, %{phase: "codex_app_server", status: "started"})

    case start_codex_session(workspace, worker_host) do
      {:ok, session} ->
        RunAudit.append(workspace, issue, :codex_app_server_started, %{
          phase: "codex_app_server",
          status: "completed",
          thread_id: session.thread_id
        })

        try do
          with {:ok, _thread_id} <-
                 ThreadIdentity.pin(workspace, session.thread_id, worker_host),
               :ok <- AppServer.set_goal(session, goal_objective(issue)) do
            RunAudit.append(workspace, issue, :codex_goal_set, %{
              phase: "codex_goal",
              status: "completed",
              goal_status: "active",
              thread_id: session.thread_id
            })

            result =
              do_run_codex_turns(
                session,
                workspace,
                issue,
                task_contract,
                codex_update_recipient,
                opts,
                issue_state_fetcher,
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
  end

  defp start_codex_session(workspace, worker_host) do
    case ThreadIdentity.read(workspace, worker_host) do
      :missing ->
        AppServer.start_session(workspace, worker_host: worker_host)

      {:ok, thread_id} ->
        AppServer.start_session(workspace, worker_host: worker_host, thread_id: thread_id)

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
         opts,
         issue_state_fetcher,
         {turn_number, max_turns}
       ) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)
    RunAudit.append(workspace, issue, :codex_turn_started, %{phase: "codex_turn", status: "started", turn_number: turn_number})

    case AppServer.run_turn(
           app_session,
           prompt,
           issue,
           on_message: codex_message_handler(codex_update_recipient, issue, workspace)
         ) do
      {:ok, turn_session} ->
        Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")
        RunAudit.append(workspace, issue, :codex_turn_completed, %{phase: "codex_turn", status: "completed", session_id: turn_session[:session_id], turn_number: turn_number})

        case continue_with_issue?(issue, task_contract, issue_state_fetcher) do
          {:continue, refreshed_issue} when turn_number < max_turns ->
            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

            RunAudit.append(workspace, refreshed_issue, :codex_turn_continuing, %{
              phase: "codex_turn",
              status: "continuing",
              reason: "issue_still_active_and_routable",
              previous_turn_number: turn_number,
              turn_number: turn_number + 1,
              issue_state: refreshed_issue.state,
              issue_labels: Enum.join(refreshed_issue.labels || [], ",")
            })

            do_run_codex_turns(
              app_session,
              workspace,
              refreshed_issue,
              task_contract,
              codex_update_recipient,
              opts,
              issue_state_fetcher,
              {turn_number + 1, max_turns}
            )

          {:continue, refreshed_issue} ->
            Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")
            RunAudit.append(workspace, refreshed_issue, :codex_max_turns_reached, %{phase: "codex_turn", status: "max_turns_reached", turn_number: turn_number})

            {:ok, completion_info(refreshed_issue, :max_turns_reached)}

          {:done, refreshed_issue} ->
            RunAudit.append(workspace, issue, :codex_continuation_check_completed, %{phase: "codex_turn", status: "done", turn_number: turn_number})
            {:ok, completion_info(refreshed_issue, :done)}

          {:error, reason} ->
            RunAudit.append(workspace, issue, :codex_continuation_check_failed, %{phase: "codex_turn", status: "failed", reason: reason, turn_number: turn_number})
            {:error, reason}
        end

      {:error, reason} = error ->
        RunAudit.append(workspace, issue, :codex_turn_failed, %{phase: "codex_turn", status: "failed", reason: reason, turn_number: turn_number})
        error
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - First check whether the implementation is already complete but the Linear handoff is missing or stale; if so, close the Linear handoff before doing more implementation.
    - If a PR, commit, or proof result already exists, verify only the missing handoff facts instead of rerunning broad setup, research, or full test gates.
    - Record the reason for the extra turn in `.symphony/run-audit.md`, including whether it was missing handoff, missing state transition, rework, or a real blocker.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp goal_objective(issue) do
    issue
    |> raw_goal_objective()
    |> String.slice(0, 4_000)
  end

  defp raw_goal_objective(%Issue{identifier: identifier, title: title}) do
    """
    Complete Linear #{identifier}: #{title}.

    Use Symphony's prepared workspace, worktree, env setup, issue prompt, and local workpad as the task packet. Preserve agent-dashboard conventions for scoped planning, verification profile selection, implementation proof, commit, PR creation, and one semantic Linear handoff. Do not stop while the issue remains actionable; either deliver a PR-backed handoff or record one real external blocker/question for human review.
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

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
