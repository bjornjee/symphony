defmodule SymphonyElixir.TeamRunner do
  @moduledoc """
  Executes a bounded multi-repository Team Mode request around the existing single-repository runner.
  """

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Codex.{AppServer, DynamicTool}
  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.{Issue, TaskContract, TeamContract}
  alias SymphonyElixir.TeamBus
  alias SymphonyElixir.TeamExecutionPublisher
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Workspace
  alias SymphonyElixir.WorkspaceArtifact

  @coordinator_id "coordinator"
  @artifact_max_bytes 32_768
  @team_planning_reviewer_role String.trim("""
                               independent principal architect. Be critical and surgical. Apply Ponytail discipline to find the simplest elegant solution while protecting product invariants
                               """)

  @spec run(Issue.t(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, update_recipient \\ nil, opts \\ []) do
    registry = Keyword.get(opts, :team_repository_registry, Config.team_repository_registry())

    with {:ok, %TaskContract{team: %TeamContract{}} = contract} <-
           task_contract(issue, Keyword.get(opts, :task_contract), registry),
         {:ok, summary} <-
           run_with_contract(
             issue,
             contract,
             opts
             |> Keyword.put(:team_repository_registry, registry)
             |> Keyword.put(:update_recipient, update_recipient)
           ) do
      send_team_completion(update_recipient, issue, summary)
      :ok
    else
      {:ok, %TaskContract{team: nil}} ->
        raise RuntimeError, "TeamRunner requires codex-team and a valid ## Team contract"

      {:error, reason} ->
        handle_run_failure(issue, update_recipient, reason)
    end
  rescue
    error ->
      if is_pid(update_recipient) do
        handle_run_failure(issue, update_recipient, {:team_runner_exception, Exception.message(error)})
      else
        reraise error, __STACKTRACE__
      end
  end

  @spec run_with_contract(Issue.t(), TaskContract.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_with_contract(%Issue{} = issue, %TaskContract{team: %TeamContract{} = team} = contract, opts) do
    agents =
      [%{agent_id: @coordinator_id, role: "coordinator", repository: nil}] ++
        Enum.map(team.repositories, fn repository ->
          %{agent_id: repository.agent_id, role: "implementer", repository: repository.workflow}
        end)

    with {:ok, bus} <- TeamBus.start_link(request_id: team.request_id, agents: agents) do
      try do
        notify_update(issue, bus, opts)
        publisher = Keyword.get(opts, :publisher, &default_publish(issue, &1, &2))
        transitioner = Keyword.get(opts, :transitioner, fn -> default_transition(issue) end)
        coordinator_runner = Keyword.get(opts, :coordinator_runner, default_coordinator_runner(issue, contract, bus, opts))
        member_runner = Keyword.get(opts, :member_runner, &default_member_runner(&1, &2, &3))
        declared = Enum.map(team.repositories, & &1.workflow)
        initial = initial_state(team, bus)

        with :ok <- publisher.("Started", %{request_id: team.request_id, repositories: declared}),
             {:ok, waves} <- coordinator_runner.(:plan, coordinator_context(initial, team)),
             :ok <- validate_waves(waves, declared),
             {:ok, state} <- execute_waves(waves, issue, contract, initial, coordinator_runner, member_runner, opts),
             :ok <- validate_member_completion(state.members, declared),
             {:ok, verdict} <- coordinator_runner.(:final, final_context(state, contract)),
             :ok <- validate_global_verdict(verdict),
             :ok <- transitioner.(),
             summary <- completion_summary(state, verdict),
             :ok <- publisher.("Finished", summary) do
          TeamBus.mark_status(bus, @coordinator_id, "completed")
          notify_update(issue, bus, opts)
          {:ok, summary}
        else
          {:error, reason} = error ->
            publisher.("Needs decision", %{
              request_id: team.request_id,
              reason: public_failure_reason(reason)
            })

            error
        end
      after
        if Process.alive?(bus), do: GenServer.stop(bus, :normal)
      end
    end
  end

  def run_with_contract(%Issue{}, %TaskContract{}, _opts), do: {:error, :team_contract_missing}

  defp task_contract(issue, expected, registry) do
    with {:ok, current} <- TaskContract.from_issue(issue, team_repository_registry: registry) do
      case expected do
        %TaskContract{digest: digest} when digest == current.digest -> {:ok, current}
        %TaskContract{} -> {:error, :team_contract_changed}
        nil -> {:ok, current}
      end
    end
  end

  defp initial_state(team, bus) do
    %{
      bus: bus,
      members: Map.new(team.repositories, &{&1.workflow, %{status: "pending"}}),
      started: MapSet.new(),
      retries: %{},
      coordinator_turn: 0,
      team: team
    }
  end

  defp execute_waves([], _issue, _contract, state, _coordinator, _member_runner, _opts), do: {:ok, state}

  defp execute_waves([wave | remaining_waves], issue, contract, state, coordinator, member_runner, opts) do
    with :ok <- revalidate_boundary(issue, contract, opts),
         {:ok, state} <- run_wave(wave, issue, contract, state, member_runner, opts) do
      remaining = remaining_workflows(remaining_waves)
      blocked = blocked_in_wave(state.members, wave)
      context = coordinator_context(%{state | coordinator_turn: state.coordinator_turn + 1}, contract.team)
      context = Map.merge(context, %{remaining: remaining, blocked: blocked, completed_wave: wave})

      with {:ok, decision} <- coordinator.(:after_wave, context),
           {:ok, next_waves, next_state} <- apply_decision(decision, remaining_waves, blocked, state) do
        execute_waves(next_waves, issue, contract, next_state, coordinator, member_runner, opts)
      end
    end
  end

  defp run_wave(wave, issue, contract, state, member_runner, opts) do
    repositories = Map.new(contract.team.repositories, &{&1.workflow, &1})
    max_concurrency = min(length(wave), Keyword.get(opts, :max_concurrent_agents, Config.settings!().agent.max_concurrent_agents))
    worker_slots = member_worker_slots(opts, max(max_concurrency, 1))

    task_results =
      wave
      |> Enum.chunk_every(length(worker_slots))
      |> Enum.flat_map(fn workflows ->
        workflows
        |> Enum.zip(worker_slots)
        |> Task.async_stream(
          fn {workflow, worker_host} ->
            repository = Map.fetch!(repositories, workflow)
            member_issue = synthetic_member_issue(issue, contract, repository)

            member_opts =
              opts
              |> Keyword.put(:worker_host, worker_host)
              |> Keyword.put(:bus, state.bus)
              |> Keyword.put(:team_parent_issue, issue)
              |> Keyword.put(:planning_reviewer_role, @team_planning_reviewer_role)
              |> Keyword.put(:planning_reviewer_effort, "high")

            try do
              member_runner.(repository, member_issue, member_opts)
            catch
              kind, reason -> {:error, {:member_exit, kind, reason}}
            end
          end,
          max_concurrency: length(workflows),
          ordered: true,
          timeout: :infinity
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, reason} -> {:error, {:member_exit, reason}}
        end)
      end)

    state =
      wave
      |> Enum.zip(task_results)
      |> Enum.reduce(state, fn {workflow, result}, acc ->
        record_member_result(acc, workflow, result)
      end)

    notify_update(issue, state.bus, opts)
    {:ok, %{state | started: Enum.reduce(wave, state.started, &MapSet.put(&2, &1))}}
  end

  defp member_worker_slots(opts, max_concurrency) do
    case Keyword.get(opts, :team_worker_hosts) do
      hosts when is_list(hosts) and hosts != [] -> Enum.take(hosts, max_concurrency)
      _other -> List.duplicate(Keyword.get(opts, :worker_host), max_concurrency)
    end
  end

  defp record_member_result(state, workflow, {:ok, completion}) when is_map(completion) do
    attempts = Map.get(state.retries, workflow, 0) + 1
    member = Map.merge(completion, %{status: "completed", attempts: attempts})
    TeamBus.mark_status(state.bus, "repo:" <> workflow, "completed", %{pr_url: completion[:pull_request_url]})

    %{
      state
      | members: Map.put(state.members, workflow, member),
        retries: Map.put(state.retries, workflow, attempts)
    }
  end

  defp record_member_result(state, workflow, {:error, reason}) do
    attempts = Map.get(state.retries, workflow, 0) + 1
    member = %{status: "blocked", reason: public_failure_reason(reason), attempts: attempts}
    TeamBus.mark_status(state.bus, "repo:" <> workflow, "blocked")

    %{
      state
      | members: Map.put(state.members, workflow, member),
        retries: Map.put(state.retries, workflow, attempts)
    }
  end

  defp record_member_result(state, workflow, other),
    do: record_member_result(state, workflow, {:error, {:invalid_member_result, other}})

  defp apply_decision(:continue, remaining_waves, [], state), do: {:ok, remaining_waves, state}
  defp apply_decision(%{action: :continue}, remaining_waves, [], state), do: {:ok, remaining_waves, state}

  defp apply_decision(%{action: :revise, waves: waves}, remaining_waves, [], state) do
    remaining = remaining_workflows(remaining_waves)

    case validate_waves(waves, remaining) do
      :ok -> {:ok, waves, state}
      {:error, _reason} -> {:error, :coordinator_revised_started_or_unknown_repository}
    end
  end

  defp apply_decision(%{action: :retry, repository: workflow}, remaining_waves, blocked, state) do
    if workflow in blocked and Map.get(state.retries, workflow, 0) < 2 do
      {:ok, [[workflow] | remaining_waves], state}
    else
      {:error, {:member_retry_rejected, workflow}}
    end
  end

  defp apply_decision(%{action: :human, reason: reason}, _remaining_waves, _blocked, _state),
    do: {:error, {:human_input_required, reason}}

  defp apply_decision(:continue, _remaining_waves, blocked, _state), do: {:error, {:members_blocked, blocked}}
  defp apply_decision(_decision, _remaining_waves, blocked, _state) when blocked != [], do: {:error, {:members_blocked, blocked}}
  defp apply_decision(decision, _remaining_waves, _blocked, _state), do: {:error, {:invalid_coordinator_decision, decision}}

  defp validate_waves(waves, declared) when is_list(waves) and is_list(declared) do
    valid_shape? = valid_waves_shape?(waves)
    flattened = if valid_shape?, do: List.flatten(waves), else: []

    cond do
      not valid_shape? -> {:error, :invalid_coordinator_waves}
      length(flattened) != length(Enum.uniq(flattened)) -> {:error, :duplicate_coordinator_repository}
      Enum.sort(flattened) != Enum.sort(declared) -> {:error, :coordinator_repository_set_mismatch}
      true -> :ok
    end
  end

  defp validate_waves(_waves, _declared), do: {:error, :invalid_coordinator_waves}

  defp valid_waves_shape?([]), do: false
  defp valid_waves_shape?(waves), do: Enum.all?(waves, &valid_wave_shape?/1)

  defp valid_wave_shape?(wave) when is_list(wave) and wave != [],
    do: Enum.all?(wave, &(is_binary(&1) and &1 != ""))

  defp valid_wave_shape?(_wave), do: false

  defp revalidate_boundary(issue, contract, opts) do
    fetcher = Keyword.get(opts, :issue_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    registry = Keyword.get(opts, :team_repository_registry, trusted_registry(contract.team))

    with {:ok, [%Issue{} = refreshed | _]} <- fetcher.([issue.id]),
         true <- Issue.has_label?(refreshed, "codex-ready") and Issue.has_label?(refreshed, "codex-team"),
         {:ok, refreshed_contract} <- TaskContract.from_issue(refreshed, team_repository_registry: registry),
         true <- refreshed_contract.digest == contract.digest do
      :ok
    else
      _other -> {:error, :team_contract_changed}
    end
  end

  defp trusted_registry(team), do: Map.new(team.repositories, &{&1.workflow, &1.trusted_config})

  defp remaining_workflows(waves), do: List.flatten(waves)

  defp blocked_in_wave(members, wave) do
    Enum.filter(wave, &(get_in(members, [&1, :status]) == "blocked"))
  end

  defp validate_member_completion(members, declared) do
    if Enum.all?(declared, &member_complete?(members[&1])) do
      :ok
    else
      {:error, :member_completion_evidence_incomplete}
    end
  end

  defp member_complete?(%{status: "completed", proof_fresh: true, pull_request_url: url})
       when is_binary(url) and url != "",
       do: true

  defp member_complete?(_member), do: false

  defp validate_global_verdict(%{verdict: verdict}) when verdict in ["pass", :pass], do: :ok
  defp validate_global_verdict(%{"verdict" => "pass"}), do: :ok
  defp validate_global_verdict(_verdict), do: {:error, :global_validation_failed}

  defp public_failure_reason({:human_input_required, _reason}),
    do: "Coordinator requested human input."

  defp public_failure_reason({:members_blocked, workflows}) when is_list(workflows),
    do: "Repository members require a decision: #{Enum.join(workflows, ", ")}."

  defp public_failure_reason({:member_retry_rejected, workflow}) when is_binary(workflow),
    do: "The retry request for #{workflow} was rejected."

  defp public_failure_reason(reason) when is_atom(reason),
    do: "Team execution stopped (#{Atom.to_string(reason)})."

  defp public_failure_reason({code, _details}) when is_atom(code),
    do: "Team execution stopped (#{Atom.to_string(code)})."

  defp public_failure_reason(_reason), do: "Team execution stopped."

  defp coordinator_context(state, team) do
    %{
      request_id: team.request_id,
      repositories: Enum.map(team.repositories, & &1.workflow),
      implementors:
        Enum.map(team.repositories, fn repository ->
          Map.take(repository, [:workflow, :owned_paths, :change, :acceptance, :verification])
        end),
      members: state.members,
      validation_goal: team.validation_goal,
      invariants: team.invariants,
      coordinator_turn: state.coordinator_turn
    }
  end

  defp final_context(state, contract) do
    coordinator_context(state, contract.team)
    |> Map.put(:acceptance_criteria, Enum.map(contract.acceptance_criteria, & &1.text))
  end

  defp completion_summary(state, verdict) do
    %{
      request_id: state.team.request_id,
      verdict: "pass",
      verdict_summary: verdict[:summary] || verdict["summary"],
      members: state.members,
      events: TeamBus.snapshot(state.bus).events
    }
  end

  @spec synthetic_member_issue(Issue.t(), TaskContract.t(), TeamContract.Repository.t()) :: Issue.t()
  def synthetic_member_issue(issue, contract, repository) do
    owned_paths = Enum.map_join(repository.owned_paths, "\n", &"- #{&1}")
    acceptance = Enum.map_join(repository.acceptance, "\n", &"- [ ] #{&1}")
    verification = Enum.map_join(repository.verification, "\n", &"- #{&1}")
    invariants = Enum.map_join(contract.team.invariants, "\n", &"- #{&1}")
    notes = contract.sections["Notes For Agent"] || "Workflow: feature"

    description = """
    ## Goal
    #{repository.change}

    ## Context
    Team request: #{issue.identifier}
    Parent contract: #{contract.digest}
    Global validation goal: #{contract.team.validation_goal}
    Invariants:
    #{invariants}

    ## Scope
    In:
    #{owned_paths}

    Out:
    - All other repository paths

    ## Acceptance Criteria
    #{acceptance}

    ## Verification
    #{verification}

    ## Risk
    #{contract.sections["Risk"]}

    ## Notes For Agent
    #{notes}
    """

    %{
      issue
      | id: "#{issue.id}:repo:#{repository.workflow}",
        identifier: "#{issue.identifier}-#{repository.workflow}",
        title: "#{issue.title} [#{repository.workflow}]",
        description: description,
        labels: ["codex-ready"]
    }
  end

  defp default_member_runner(repository, member_issue, opts) do
    bus = Keyword.fetch!(opts, :bus)
    parent_issue = Keyword.fetch!(opts, :team_parent_issue)
    parent = self()
    runner = Keyword.get(opts, :agent_runner, &AgentRunner.run/3)
    {:ok, member_contract} = TaskContract.from_issue(member_issue)

    team_send = fn recipient, kind, message ->
      result = TeamBus.send_event(bus, repository.agent_id, recipient, kind, message)
      notify_update(parent_issue, bus, opts)
      result
    end

    observer = fn session, message ->
      notify_activity(parent_issue, repository.agent_id, message, opts)

      case message do
        %{event: :session_started, turn_id: turn_id, session_id: session_id} ->
          TeamBus.register(bus, repository.agent_id, %{
            thread_id: session.thread_id,
            latest_session_id: session_id,
            workspace: session.workspace,
            steer: fn text -> AppServer.steer_turn(session, turn_id, text) end
          })

          notify_update(parent_issue, bus, opts)

        _other ->
          :ok
      end
    end

    handoff_publisher = fn _issue, _contract, evidence, publisher_opts ->
      send(parent, {:member_evidence, repository.workflow, evidence})

      {:ok,
       %{
         comment_id: "team-member-#{repository.workflow}",
         issue_state: Keyword.fetch!(publisher_opts, :handoff_state)
       }}
    end

    human_review_publisher = fn _issue, _key_parts, _body, _publisher_opts ->
      {:ok, "team-member-blocker"}
    end

    runner_opts =
      opts
      |> Keyword.delete(:publisher)
      |> Keyword.put(:task_contract, member_contract)
      |> Keyword.put(:reasoning_effort, "high")
      |> Keyword.put(:thread_name, "[#{member_issue.identifier} · #{repository.workflow}] implementer")
      |> Keyword.put(:extra_dynamic_tools, team_send_tool_specs())
      |> Keyword.put(:team_tool_executor, fn tool, arguments -> DynamicTool.execute(tool, arguments, team_send: team_send) end)
      |> Keyword.put(:codex_message_observer, observer)
      |> Keyword.put(:workspace_creator, fn issue, worker_host ->
        Workspace.create_for_repository(issue, repository.trusted_config, worker_host)
      end)
      |> Keyword.put(:before_run_hook_runner, fn workspace, issue, worker_host ->
        Workspace.run_repository_before_run_hook(workspace, issue, repository.trusted_config, worker_host)
      end)
      |> Keyword.put(:after_run_hook_runner, fn workspace, issue, worker_host ->
        Workspace.run_repository_after_run_hook(workspace, issue, repository.trusted_config, worker_host)
      end)
      |> Keyword.put(:issue_fetcher, fn _ids -> {:ok, [member_issue]} end)
      |> Keyword.put(:issue_state_fetcher, fn _ids -> {:ok, [member_issue]} end)
      |> Keyword.put(:issue_routable_predicate, fn _issue -> true end)
      |> Keyword.put(:review_exhausted_handler, fn _issue, _contract, _candidate, _review ->
        {:error, :plan_review_exhausted}
      end)
      |> Keyword.put(:human_review_publisher, human_review_publisher)
      |> Keyword.put(:handoff_publisher, handoff_publisher)

    try do
      :ok = runner.(member_issue, self(), runner_opts)
      member_issue_id = member_issue.id

      receive do
        {:worker_completion_info, ^member_issue_id, %{outcome: :human_review_required} = completion} ->
          {:error, {:member_human_review_required, completion}}

        {:worker_completion_info, ^member_issue_id, completion} ->
          {:ok, Map.put(completion, :proof_fresh, true)}
      after
        0 -> {:error, :member_completion_info_missing}
      end
    rescue
      error -> {:error, {:member_runner_failed, Exception.message(error)}}
    end
  end

  defp default_coordinator_runner(issue, contract, bus, opts) do
    thread_key = {:team_coordinator_thread, make_ref()}
    fn mode, context -> run_coordinator_turn(issue, contract, bus, mode, context, thread_key, opts) end
  end

  defp run_coordinator_turn(issue, contract, bus, mode, context, thread_key, opts) do
    worker_host = Keyword.get(opts, :worker_host)
    coordinator_issue = %{issue | identifier: "#{issue.identifier}-team-coordinator"}

    trusted_config = %{
      "workspace" => %{"root" => Path.join(Config.settings!().workspace.root, "teams")},
      "hooks" => %{}
    }

    with {:ok, workspace} <- Workspace.create_for_repository(coordinator_issue, trusted_config, worker_host),
         {:ok, session} <- start_coordinator_session(workspace, worker_host, mode, thread_key) do
      try do
        with :ok <- AppServer.set_thread_name(session, "[#{issue.identifier} · team] coordinator"),
             :ok <- AppServer.set_goal(session, "Coordinate Team Mode request #{issue.identifier} without expanding its approved contract."),
             artifact_path <- coordinator_artifact_path(workspace, mode, context),
             prompt <- coordinator_prompt(mode, context, contract, artifact_path),
             {:ok, _turn} <-
               AppServer.run_turn(session, prompt, issue,
                 effort: "medium",
                 tool_executor: fn tool, arguments ->
                   DynamicTool.execute(tool, arguments,
                     team_send: fn recipient, kind, message ->
                       result = TeamBus.send_event(bus, @coordinator_id, recipient, kind, message)
                       notify_update(issue, bus, opts)
                       result
                     end
                   )
                 end,
                 on_message: coordinator_message_observer(issue, bus, session, opts)
               ),
             {:ok, payload} <- read_coordinator_artifact(artifact_path, worker_host) do
          normalize_coordinator_result(mode, payload)
        end
      after
        AppServer.stop_session(session)
        TeamBus.mark_status(bus, @coordinator_id, "waiting")
      end
    end
  end

  defp start_coordinator_session(workspace, worker_host, :plan, thread_key) do
    opts = [worker_host: worker_host, dynamic_tools: team_send_tool_specs()]

    case AppServer.start_session(workspace, opts) do
      {:ok, session} = result ->
        Process.put(thread_key, session.thread_id)
        result

      {:error, _reason} = error ->
        error
    end
  end

  defp start_coordinator_session(workspace, worker_host, _mode, thread_key) do
    opts = [worker_host: worker_host, dynamic_tools: team_send_tool_specs()]

    case Process.get(thread_key) do
      thread_id when is_binary(thread_id) ->
        AppServer.start_session(workspace, Keyword.put(opts, :thread_id, thread_id))

      _missing ->
        {:error, :coordinator_thread_missing}
    end
  end

  defp coordinator_message_observer(issue, bus, session, opts) do
    fn message ->
      notify_activity(issue, @coordinator_id, message, opts)

      case message do
        %{event: :session_started, turn_id: turn_id, session_id: session_id} ->
          TeamBus.register(bus, @coordinator_id, %{
            thread_id: session.thread_id,
            latest_session_id: session_id,
            workspace: session.workspace,
            steer: fn text -> AppServer.steer_turn(session, turn_id, text) end
          })

          notify_update(issue, bus, opts)

        _message ->
          :ok
      end
    end
  end

  defp team_send_tool_specs do
    DynamicTool.tool_specs(team_send: true)
    |> Enum.filter(&(&1["name"] == "team_send"))
  end

  defp coordinator_artifact_path(workspace, mode, context) do
    digest = :crypto.hash(:sha256, Jason.encode!([mode, context])) |> Base.encode16(case: :lower)
    Path.join(workspace, ".symphony/team-#{String.slice(digest, 0, 16)}.json")
  end

  defp coordinator_prompt(mode, context, contract, artifact_path) do
    action =
      case mode do
        :plan ->
          """
          The declared repositories are the implementors. A pending member has not started yet.
          Record a plan as JSON: {"waves":[["workflow-a","workflow-b"],...]}. Include every declared repository exactly once.
          If sequencing truly requires operator input, record {"action":"human","reason":"..."}.
          """

        :after_wave ->
          """
          Record one JSON decision: {"action":"continue"}, {"action":"revise","waves":[...]},
          {"action":"retry","repository":"..."}, or {"action":"human","reason":"..."}.
          """

        :final ->
          "Record a global verdict as JSON: {\"verdict\":\"pass|fail\",\"summary\":\"...\"}."
      end

    """
    You are the coordinator for Team Mode request #{contract.team.request_id}.
    You may sequence only the declared repositories and may not change scope or invariants.
    Repositories: #{Jason.encode!(Enum.map(contract.team.repositories, & &1.workflow))}
    Sealed implementor assignments: #{Jason.encode!(context.implementors)}
    Validation goal: #{contract.team.validation_goal}
    Invariants: #{Jason.encode!(contract.team.invariants)}
    Current bounded state: #{Jason.encode!(context)}

    #{action}
    Write only the decision JSON to #{artifact_path} before ending this turn.
    """
  end

  defp read_coordinator_artifact(path, worker_host) do
    with {:ok, content} <- WorkspaceArtifact.read(path, @artifact_max_bytes, worker_host),
         {:ok, payload} when is_map(payload) or is_list(payload) <- Jason.decode(content) do
      {:ok, payload}
    else
      :missing -> {:error, :coordinator_artifact_missing}
      {:ok, _payload} -> {:error, :coordinator_artifact_invalid}
      {:error, reason} -> {:error, {:coordinator_artifact_invalid, reason}}
    end
  end

  defp normalize_coordinator_result(:plan, waves) when is_list(waves), do: {:ok, waves}
  defp normalize_coordinator_result(:plan, %{"waves" => waves}) when is_list(waves), do: {:ok, waves}

  defp normalize_coordinator_result(:plan, %{"action" => "human", "reason" => reason})
       when is_binary(reason),
       do: {:error, {:human_input_required, reason}}

  defp normalize_coordinator_result(:final, payload) when is_map(payload), do: {:ok, payload}
  defp normalize_coordinator_result(:after_wave, %{"action" => "continue"}), do: {:ok, :continue}

  defp normalize_coordinator_result(:after_wave, %{"action" => "revise", "waves" => waves}),
    do: {:ok, %{action: :revise, waves: waves}}

  defp normalize_coordinator_result(:after_wave, %{"action" => "retry", "repository" => repository}),
    do: {:ok, %{action: :retry, repository: repository}}

  defp normalize_coordinator_result(:after_wave, %{"action" => "human", "reason" => reason}),
    do: {:ok, %{action: :human, reason: reason}}

  defp normalize_coordinator_result(_mode, payload), do: {:error, {:invalid_coordinator_artifact, payload}}

  defp default_publish(issue, status, summary), do: TeamExecutionPublisher.publish(issue, status, summary)
  defp default_transition(issue), do: Tracker.update_issue_state(issue.id, Config.settings!().tracker.handoff_state)

  defp notify_update(issue, bus, opts) do
    case Keyword.get(opts, :update_recipient) do
      recipient when is_pid(recipient) -> send(recipient, {:team_runtime_info, issue.id, TeamBus.snapshot(bus)})
      _other -> :ok
    end
  end

  defp notify_activity(issue, agent_id, message, opts) do
    case Keyword.get(opts, :update_recipient) do
      recipient when is_pid(recipient) ->
        send(
          recipient,
          {:team_activity, issue.id,
           %{
             agent_id: agent_id,
             event: Map.get(message, :event, :notification),
             timestamp: Map.get(message, :timestamp, DateTime.utc_now())
           }}
        )

      _other ->
        :ok
    end
  end

  defp send_team_completion(recipient, issue, summary) when is_pid(recipient) do
    send(recipient, {:team_completion_info, issue.id, summary})
  end

  defp send_team_completion(_recipient, _issue, _summary), do: :ok

  defp handle_run_failure(issue, recipient, reason) when is_pid(recipient) do
    send(recipient, {:team_blocked_info, issue.id, %{reason: public_failure_reason(reason)}})
    :ok
  end

  defp handle_run_failure(issue, _recipient, reason) do
    raise RuntimeError, "Team run failed for #{issue.identifier}: #{inspect(reason)}"
  end
end
