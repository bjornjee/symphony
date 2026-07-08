defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, RunAudit, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        RunAudit.start(workspace, issue, %{worker_host: worker_host_for_log(worker_host)})
        RunAudit.append(workspace, issue, :workspace_prepared, %{phase: "workspace", status: "completed", workspace_path: workspace})

        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          run_with_workspace(workspace, issue, codex_update_recipient, opts, worker_host)
        after
          RunAudit.append(workspace, issue, :after_run_hook_started, %{phase: "workspace", status: "started"})
          Workspace.run_after_run_hook(workspace, issue, worker_host)
          RunAudit.append(workspace, issue, :after_run_hook_completed, %{phase: "workspace", status: "completed"})
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
        result

      {:error, reason} = error ->
        RunAudit.append(workspace, issue, :before_run_hook_failed, %{phase: "workspace", status: "failed", reason: reason})
        error
    end
  end

  defp record_run_result(workspace, issue, :ok) do
    RunAudit.append(workspace, issue, :run_completed, %{phase: "run", status: "completed"})
  end

  defp record_run_result(workspace, issue, {:error, reason}) do
    RunAudit.append(workspace, issue, :run_failed, %{phase: "run", status: "failed", reason: reason})
  end

  defp record_run_result(_workspace, _issue, _result), do: :ok

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

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    RunAudit.append(workspace, issue, :codex_app_server_starting, %{phase: "codex_app_server", status: "started"})

    case AppServer.start_session(workspace, worker_host: worker_host) do
      {:ok, session} ->
        RunAudit.append(workspace, issue, :codex_app_server_started, %{phase: "codex_app_server", status: "completed"})

        try do
          case AppServer.set_goal(session, goal_objective(issue)) do
            :ok ->
              RunAudit.append(workspace, issue, :codex_goal_set, %{phase: "codex_goal", status: "completed"})

              do_run_codex_turns(
                session,
                workspace,
                issue,
                codex_update_recipient,
                opts,
                issue_state_fetcher,
                1,
                max_turns
              )

            {:error, reason} = error ->
              RunAudit.append(workspace, issue, :codex_goal_failed, %{phase: "codex_goal", status: "failed", reason: reason})
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

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
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

        case continue_with_issue?(issue, issue_state_fetcher) do
          {:continue, refreshed_issue} when turn_number < max_turns ->
            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")
            RunAudit.append(workspace, refreshed_issue, :codex_turn_continuing, %{phase: "codex_turn", status: "continuing", turn_number: turn_number + 1})

            do_run_codex_turns(
              app_session,
              workspace,
              refreshed_issue,
              codex_update_recipient,
              opts,
              issue_state_fetcher,
              turn_number + 1,
              max_turns
            )

          {:continue, refreshed_issue} ->
            Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")
            RunAudit.append(workspace, refreshed_issue, :codex_max_turns_reached, %{phase: "codex_turn", status: "max_turns_reached", turn_number: turn_number})

            :ok

          {:done, _refreshed_issue} ->
            RunAudit.append(workspace, issue, :codex_continuation_check_completed, %{phase: "codex_turn", status: "done", turn_number: turn_number})
            :ok

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

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

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
