defmodule SymphonyElixir.TeamRunnerTest do
  use ExUnit.Case, async: true

  import SymphonyElixir.TaskContractFixtures

  alias SymphonyElixir.{AgentRunner, Orchestrator}
  alias SymphonyElixir.Linear.TaskContract
  alias SymphonyElixir.TeamRunner

  test "ordinary contracts stay on AgentRunner and Team contracts route explicitly" do
    assert {:ok, ordinary} = TaskContract.from_issue(issue())
    {_issue, team} = team_issue_and_contract()

    assert Orchestrator.runner_for_contract_for_test(ordinary) == AgentRunner
    assert Orchestrator.runner_for_contract_for_test(team) == TeamRunner
  end

  test "public runner emits one team completion and rejects ordinary contracts" do
    {task, contract} = team_issue_and_contract()
    parent = self()
    registry = Map.new(contract.team.repositories, &{&1.workflow, &1.trusted_config})

    coordinator = fn
      :plan, _context -> {:ok, [["application", "infrastructure"]]}
      :after_wave, _context -> {:ok, :continue}
      :final, _context -> {:ok, %{verdict: "pass"}}
    end

    member = fn repository, _member_issue, _opts ->
      {:ok,
       %{
         pull_request_url: "https://github.com/example/#{repository.workflow}/pull/1",
         proof_fresh: true
       }}
    end

    assert :ok =
             TeamRunner.run(task, parent,
               task_contract: contract,
               team_repository_registry: registry,
               coordinator_runner: coordinator,
               member_runner: member,
               issue_fetcher: stable_issue_fetcher(task),
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end
             )

    assert_receive {:team_completion_info, "issue-1", %{verdict: "pass"}}, 1_000

    assert_raise RuntimeError, ~r/requires codex-team/, fn ->
      TeamRunner.run(issue(), nil)
    end
  end

  test "public runner rejects an expected contract whose digest no longer matches" do
    {task, contract} = team_issue_and_contract()
    registry = Map.new(contract.team.repositories, &{&1.workflow, &1.trusted_config})

    assert_raise RuntimeError, ~r/team_contract_changed/, fn ->
      TeamRunner.run(task, nil,
        task_contract: %{contract | digest: "stale-digest"},
        team_repository_registry: registry
      )
    end
  end

  test "public runner reports a bounded Team failure without crashing the orchestrator worker" do
    {task, contract} = team_issue_and_contract()
    parent = self()
    registry = Map.new(contract.team.repositories, &{&1.workflow, &1.trusted_config})

    assert :ok =
             TeamRunner.run(task, parent,
               task_contract: contract,
               team_repository_registry: registry,
               coordinator_runner: fn :plan, _context ->
                 {:error, {:human_input_required, "private coordinator detail"}}
               end,
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end
             )

    assert_receive {:team_blocked_info, "issue-1", %{reason: "Coordinator requested human input."}},
                   1_000
  end

  test "public runner converts an unexpected Team exception into a terminal outcome" do
    {task, contract} = team_issue_and_contract()
    parent = self()
    registry = Map.new(contract.team.repositories, &{&1.workflow, &1.trusted_config})

    assert :ok =
             TeamRunner.run(task, parent,
               task_contract: contract,
               team_repository_registry: registry,
               coordinator_runner: fn :plan, _context ->
                 raise Protocol.UndefinedError, protocol: Jason.Encoder, value: {:member_runner_failed, :boom}
               end,
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end
             )

    assert_receive {:team_blocked_info, "issue-1", %{reason: "Team execution stopped (team_runner_exception)."}},
                   1_000
  end

  test "synthetic members keep tracker reads and review exhaustion inside the Team boundary" do
    {task, contract} = team_issue_and_contract()
    parent = self()

    coordinator = fn
      :plan, _context -> {:ok, [["application", "infrastructure"]]}
      :after_wave, _context -> {:ok, :continue}
      :final, _context -> {:ok, %{verdict: "pass"}}
    end

    agent_runner = fn member_issue, recipient, opts ->
      assert {:ok, [^member_issue]} = opts[:issue_fetcher].([member_issue.id])
      assert {:ok, [^member_issue]} = opts[:issue_state_fetcher].([member_issue.id])
      assert opts[:issue_routable_predicate].(member_issue)
      refute Keyword.has_key?(opts, :publisher)
      assert {:error, :plan_review_exhausted} = opts[:review_exhausted_handler].(nil, nil, nil, nil)

      assert {:ok, "team-member-blocker"} =
               opts[:human_review_publisher].(member_issue, ["proof"], "blocked", handoff_state: "Human Review")

      send(parent, {:synthetic_member_checked, member_issue.id})

      send(
        recipient,
        {:worker_completion_info, member_issue.id,
         %{
           pull_request_url: "https://github.com/example/symphony/pull/1"
         }}
      )

      :ok
    end

    assert {:ok, %{verdict: "pass"}} =
             TeamRunner.run_with_contract(task, contract,
               coordinator_runner: coordinator,
               agent_runner: agent_runner,
               issue_fetcher: stable_issue_fetcher(task),
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end,
               max_concurrent_agents: 2
             )

    assert_receive {:synthetic_member_checked, "issue-1:repo:application"}
    assert_receive {:synthetic_member_checked, "issue-1:repo:infrastructure"}
  end

  test "synthetic Human Review completions remain member blockers" do
    {task, contract} = team_issue_and_contract()

    coordinator = fn
      :plan, _context ->
        {:ok, [["application", "infrastructure"]]}

      :after_wave, %{blocked: ["application", "infrastructure"]} ->
        {:ok, %{action: :human, reason: "member proof exhausted"}}
    end

    agent_runner = fn member_issue, recipient, _opts ->
      send(
        recipient,
        {:worker_completion_info, member_issue.id,
         %{
           outcome: :human_review_required,
           blocker_comment_id: "team-member-blocker",
           issue_state: "Human Review"
         }}
      )

      :ok
    end

    assert {:error, {:human_input_required, "member proof exhausted"}} =
             TeamRunner.run_with_contract(task, contract,
               coordinator_runner: coordinator,
               agent_runner: agent_runner,
               issue_fetcher: stable_issue_fetcher(task),
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end,
               max_concurrent_agents: 2
             )
  end

  test "synthetic members are scoped to their declared owned paths" do
    {task, contract} = team_issue_and_contract()
    application = Enum.find(contract.team.repositories, &(&1.workflow == "application"))
    infrastructure = Enum.find(contract.team.repositories, &(&1.workflow == "infrastructure"))

    application_issue = TeamRunner.synthetic_member_issue(task, contract, application)
    infrastructure_issue = TeamRunner.synthetic_member_issue(task, contract, infrastructure)

    assert application_issue.description =~ "In:\n- lib/api.ex"
    assert application_issue.description =~ "Out:\n- All other repository paths"
    refute application_issue.description =~ "infra/main.tf"
    assert application_issue.identifier == "PIN-14-application"
    assert infrastructure_issue.identifier == "PIN-14-infrastructure"
  end

  test "run_with_contract rejects a contract without a Team section" do
    assert {:ok, ordinary} = TaskContract.from_issue(issue())
    assert {:error, :team_contract_missing} = TeamRunner.run_with_contract(issue(), ordinary, [])
  end

  test "rejects a non-list coordinator plan" do
    {task, contract} = team_issue_and_contract()

    assert {:error, :invalid_coordinator_waves} =
             TeamRunner.run_with_contract(task, contract,
               coordinator_runner: fn :plan, _context -> {:ok, :invalid} end,
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end
             )
  end

  test "rejects an empty coordinator plan" do
    {task, contract} = team_issue_and_contract()

    assert {:error, :invalid_coordinator_waves} =
             TeamRunner.run_with_contract(task, contract,
               coordinator_runner: fn :plan, _context -> {:ok, []} end,
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end
             )
  end

  test "initial coordinator state identifies every declared repository as a pending member" do
    {task, contract} = team_issue_and_contract()

    coordinator = fn :plan, context ->
      assert context.members == %{
               "application" => %{status: "pending"},
               "infrastructure" => %{status: "pending"}
             }

      assert context.implementors == [
               %{
                 workflow: "application",
                 owned_paths: ["lib/api.ex"],
                 change: "Add API behavior.",
                 acceptance: ["Existing callers remain compatible."],
                 verification: ["mix test"]
               },
               %{
                 workflow: "infrastructure",
                 owned_paths: ["infra/main.tf"],
                 change: "Deploy supporting configuration.",
                 acceptance: ["The application can use the configuration."],
                 verification: ["terraform validate"]
               }
             ]

      {:error, :stop_after_context_assertion}
    end

    assert {:error, :stop_after_context_assertion} =
             TeamRunner.run_with_contract(task, contract,
               coordinator_runner: coordinator,
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end
             )
  end

  test "turns an invalid member result into a blocked member" do
    {task, contract} = team_issue_and_contract()

    coordinator = fn
      :plan, _context -> {:ok, [["application", "infrastructure"]]}
      :after_wave, _context -> {:ok, %{action: :continue}}
    end

    assert {:error, {:members_blocked, ["application", "infrastructure"]}} =
             TeamRunner.run_with_contract(task, contract,
               coordinator_runner: coordinator,
               member_runner: fn _repository, _member_issue, _opts -> :unexpected end,
               issue_fetcher: stable_issue_fetcher(task),
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end
             )
  end

  test "rejects an unknown coordinator decision after a successful wave" do
    {task, contract} = team_issue_and_contract()

    coordinator = fn
      :plan, _context -> {:ok, [["application", "infrastructure"]]}
      :after_wave, _context -> {:ok, :pause}
    end

    assert {:error, {:invalid_coordinator_decision, :pause}} =
             TeamRunner.run_with_contract(task, contract,
               coordinator_runner: coordinator,
               member_runner: &successful_member/3,
               issue_fetcher: stable_issue_fetcher(task),
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end
             )
  end

  test "rejects a retry request for a repository that is not blocked" do
    {task, contract} = team_issue_and_contract()

    coordinator = fn
      :plan, _context -> {:ok, [["application", "infrastructure"]]}
      :after_wave, _context -> {:ok, %{action: :retry, repository: "application"}}
    end

    assert {:error, {:member_retry_rejected, "application"}} =
             TeamRunner.run_with_contract(task, contract,
               coordinator_runner: coordinator,
               member_runner: &successful_member/3,
               issue_fetcher: stable_issue_fetcher(task),
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end
             )
  end

  test "a team waits until capacity can reserve all repository members" do
    {_issue, team} = team_issue_and_contract()

    one_slot_used = %Orchestrator.State{
      max_concurrent_agents: 2,
      running: %{"ordinary" => %{reserved_slots: 1}}
    }

    assert Orchestrator.reservation_fits_for_test(team, %Orchestrator.State{
             max_concurrent_agents: 2
           })

    refute Orchestrator.reservation_fits_for_test(team, one_slot_used)
  end

  test "runs repositories inside a wave in parallel" do
    {issue, contract} = team_issue_and_contract()
    parent = self()

    coordinator = fn
      :plan, _context -> {:ok, [["application", "infrastructure"]]}
      :after_wave, _context -> {:ok, :continue}
      :final, _context -> {:ok, %{verdict: "pass", summary: "All repositories align."}}
    end

    member = fn repository, _member_issue, opts ->
      assert opts[:planning_reviewer_role] =~ "principal architect"
      assert opts[:planning_reviewer_role] =~ "Ponytail discipline"
      assert opts[:planning_reviewer_effort] == "high"
      send(parent, {:member_started, repository.workflow, opts[:worker_host], self()})
      receive do: (:release -> :ok)
      {:ok, %{pull_request_url: "https://github.com/example/#{repository.workflow}/pull/1", proof_fresh: true}}
    end

    task =
      Task.async(fn ->
        TeamRunner.run_with_contract(issue, contract,
          coordinator_runner: coordinator,
          member_runner: member,
          issue_fetcher: stable_issue_fetcher(issue),
          publisher: fn _status, _summary -> :ok end,
          transitioner: fn -> :ok end,
          update_recipient: parent,
          max_concurrent_agents: 2,
          team_worker_hosts: ["worker-a", "worker-b"]
        )
      end)

    assert_receive {:team_runtime_info, "issue-1", %{request_id: "PIN-14"}}, 1_000
    assert_receive {:member_started, "application", "worker-a", application_pid}, 1_000
    assert_receive {:member_started, "infrastructure", "worker-b", infrastructure_pid}, 1_000
    send(application_pid, :release)
    send(infrastructure_pid, :release)

    assert {:ok, summary} = Task.await(task, 1_000)
    assert summary.verdict == "pass"
    assert Map.keys(summary.members) |> Enum.sort() == ["application", "infrastructure"]
  end

  test "runs waves sequentially and accepts revisions only for repositories not started" do
    {issue, contract} = team_issue_and_contract()
    parent = self()

    coordinator = fn
      :plan, _context -> {:ok, [["application"], ["infrastructure"]]}
      :after_wave, %{remaining: ["infrastructure"]} -> {:ok, %{action: :revise, waves: [["infrastructure"]]}}
      :after_wave, %{remaining: []} -> {:ok, :continue}
      :final, _context -> {:ok, %{verdict: "pass"}}
    end

    member = fn repository, _member_issue, _opts ->
      send(parent, {:member_started, repository.workflow, self()})
      receive do: (:release -> :ok)
      {:ok, %{pull_request_url: "https://github.com/example/#{repository.workflow}/pull/1", proof_fresh: true}}
    end

    task =
      Task.async(fn ->
        TeamRunner.run_with_contract(issue, contract,
          coordinator_runner: coordinator,
          member_runner: member,
          issue_fetcher: stable_issue_fetcher(issue),
          publisher: fn _status, _summary -> :ok end,
          transitioner: fn -> :ok end,
          max_concurrent_agents: 2
        )
      end)

    assert_receive {:member_started, "application", application_pid}, 1_000
    refute_receive {:member_started, "infrastructure", _pid}, 50
    send(application_pid, :release)

    assert_receive {:member_started, "infrastructure", infrastructure_pid}, 1_000
    send(infrastructure_pid, :release)
    assert {:ok, _summary} = Task.await(task, 1_000)
  end

  test "rejects duplicate plans and revisions that include started repositories" do
    {issue, contract} = team_issue_and_contract()

    assert {:error, :duplicate_coordinator_repository} =
             TeamRunner.run_with_contract(issue, contract,
               coordinator_runner: fn :plan, _context ->
                 {:ok, [["application", "application"]]}
               end,
               member_runner: fn _repository, _member_issue, _opts -> flunk("invalid plans must not start") end,
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end
             )

    coordinator = fn
      :plan, _context ->
        {:ok, [["application"], ["infrastructure"]]}

      :after_wave, %{remaining: ["infrastructure"]} ->
        {:ok, %{action: :revise, waves: [["application"]]}}
    end

    assert {:error, :coordinator_revised_started_or_unknown_repository} =
             TeamRunner.run_with_contract(issue, contract,
               coordinator_runner: coordinator,
               member_runner: fn repository, _member_issue, _opts ->
                 {:ok,
                  %{
                    pull_request_url: "https://github.com/example/#{repository.workflow}/pull/1",
                    proof_fresh: true
                  }}
               end,
               issue_fetcher: stable_issue_fetcher(issue),
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end
             )
  end

  test "fails closed on stale member proof and a non-passing global verdict" do
    {issue, contract} = team_issue_and_contract()

    coordinator = fn
      :plan, _context -> {:ok, [["application", "infrastructure"]]}
      :after_wave, _context -> {:ok, :continue}
      :final, _context -> {:ok, %{verdict: "fail"}}
    end

    stale_member = fn repository, _member_issue, _opts ->
      {:ok,
       %{
         pull_request_url: "https://github.com/example/#{repository.workflow}/pull/1",
         proof_fresh: false
       }}
    end

    assert {:error, :member_completion_evidence_incomplete} =
             TeamRunner.run_with_contract(issue, contract,
               coordinator_runner: coordinator,
               member_runner: stale_member,
               issue_fetcher: stable_issue_fetcher(issue),
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end
             )

    fresh_member = fn repository, _member_issue, _opts ->
      {:ok,
       %{
         pull_request_url: "https://github.com/example/#{repository.workflow}/pull/1",
         proof_fresh: true
       }}
    end

    assert {:error, :global_validation_failed} =
             TeamRunner.run_with_contract(issue, contract,
               coordinator_runner: coordinator,
               member_runner: fresh_member,
               issue_fetcher: stable_issue_fetcher(issue),
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end
             )
  end

  test "lets the coordinator retry one blocked member once" do
    {issue, contract} = team_issue_and_contract()
    attempts = Agent.start_link(fn -> %{} end) |> elem(1)

    coordinator = fn
      :plan, _context ->
        {:ok, [["application"], ["infrastructure"]]}

      :after_wave, %{blocked: ["application"]} ->
        {:ok, %{action: :retry, repository: "application"}}

      :after_wave, _context ->
        {:ok, :continue}

      :final, _context ->
        {:ok, %{verdict: "pass"}}
    end

    member = fn repository, _member_issue, _opts ->
      attempt = Agent.get_and_update(attempts, fn state -> {Map.get(state, repository.workflow, 0) + 1, Map.update(state, repository.workflow, 1, &(&1 + 1))} end)

      if repository.workflow == "application" and attempt == 1 do
        {:error, :blocked}
      else
        {:ok, %{pull_request_url: "https://github.com/example/#{repository.workflow}/pull/1", proof_fresh: true}}
      end
    end

    assert {:ok, summary} =
             TeamRunner.run_with_contract(issue, contract,
               coordinator_runner: coordinator,
               member_runner: member,
               issue_fetcher: stable_issue_fetcher(issue),
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end,
               max_concurrent_agents: 2
             )

    assert summary.members["application"].attempts == 2
  end

  test "escalates a blocker without publishing coordinator chatter" do
    {issue, contract} = team_issue_and_contract()
    parent = self()

    coordinator = fn
      :plan, _context -> {:ok, [["application"], ["infrastructure"]]}
      :after_wave, %{blocked: ["application"]} -> {:ok, %{action: :human, reason: "secret=do-not-publish"}}
    end

    publisher = fn status, summary ->
      send(parent, {:published, status, summary})
      :ok
    end

    assert {:error, {:human_input_required, "secret=do-not-publish"}} =
             TeamRunner.run_with_contract(issue, contract,
               coordinator_runner: coordinator,
               member_runner: fn
                 %{workflow: "application"}, _member_issue, _opts -> {:error, :blocked}
                 _repository, _member_issue, _opts -> flunk("later waves must not start")
               end,
               issue_fetcher: stable_issue_fetcher(issue),
               publisher: publisher,
               transitioner: fn -> :ok end
             )

    assert_received {:published, "Needs decision", %{reason: "Coordinator requested human input."}}
  end

  test "records a crashed member as blocked instead of dropping its workflow" do
    {issue, contract} = team_issue_and_contract()

    coordinator = fn
      :plan, _context ->
        {:ok, [["application", "infrastructure"]]}

      :after_wave, %{blocked: ["application"]} = context ->
        assert is_binary(Jason.encode!(context))
        {:ok, :continue}
    end

    assert {:error, {:members_blocked, ["application"]}} =
             TeamRunner.run_with_contract(issue, contract,
               coordinator_runner: coordinator,
               member_runner: fn
                 %{workflow: "application"}, _member_issue, _opts ->
                   exit(:member_crashed)

                 repository, _member_issue, _opts ->
                   {:ok,
                    %{
                      pull_request_url: "https://github.com/example/#{repository.workflow}/pull/1",
                      proof_fresh: true
                    }}
               end,
               issue_fetcher: stable_issue_fetcher(issue),
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end
             )
  end

  test "stops at a wave boundary when codex-team is removed" do
    {issue, contract} = team_issue_and_contract()
    without_team = %{issue | labels: ["codex-ready"]}

    assert {:error, :team_contract_changed} =
             TeamRunner.run_with_contract(issue, contract,
               coordinator_runner: fn :plan, _context -> {:ok, [["application"], ["infrastructure"]]} end,
               member_runner: fn _repository, _member_issue, _opts -> flunk("member must not start") end,
               issue_fetcher: fn [_id] -> {:ok, [without_team]} end,
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end
             )
  end

  defp stable_issue_fetcher(issue), do: fn [_id] -> {:ok, [issue]} end

  defp successful_member(repository, _member_issue, _opts) do
    {:ok,
     %{
       pull_request_url: "https://github.com/example/#{repository.workflow}/pull/1",
       proof_fresh: true
     }}
  end

  defp team_issue_and_contract do
    registry = %{
      "application" => %{
        "repository_id" => "example/application",
        "workspace" => %{"root" => "/workspaces/application"},
        "hooks" => %{"after_create" => "git clone app ."}
      },
      "infrastructure" => %{
        "repository_id" => "example/infrastructure",
        "workspace" => %{"root" => "/workspaces/infrastructure"},
        "hooks" => %{"after_create" => "git clone infra ."}
      }
    }

    team_yaml = """
    repositories:
      - workflow: application
        owned_paths:
          - lib/api.ex
        change: Add API behavior.
        acceptance:
          - Existing callers remain compatible.
        verification:
          - mix test
      - workflow: infrastructure
        owned_paths:
          - infra/main.tf
        change: Deploy supporting configuration.
        acceptance:
          - The application can use the configuration.
        verification:
          - terraform validate
    validation_goal: The changes work together.
    invariants:
      - Infrastructure lands first.
    """

    issue = issue(%{labels: ["codex-ready", "codex-team"], description: valid_description() <> "\n\n## Team\n" <> team_yaml})
    {:ok, contract} = TaskContract.from_issue(issue, team_repository_registry: registry)
    {issue, contract}
  end
end
