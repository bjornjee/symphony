defmodule SymphonyElixir.TeamRunnerBoundaryTest do
  use SymphonyElixir.TestSupport

  import SymphonyElixir.TaskContractFixtures, only: [issue: 1, valid_description: 0]

  alias SymphonyElixir.Linear.TaskContract
  alias SymphonyElixir.TeamRunner

  test "default coordinator starts fresh per Team run and resumes one thread between waves" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-team-runner-boundary-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "coordinator.trace")
    File.mkdir_p!(test_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    File.write!(codex_binary, fake_codex_script(trace_file))
    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    {task, contract} = team_issue_and_contract(workspace_root)

    member_runner = fn repository, _member_issue, _opts ->
      {:ok,
       %{
         pull_request_url: "https://github.com/example/#{repository.workflow}/pull/1",
         proof_fresh: true
       }}
    end

    result =
      TeamRunner.run_with_contract(task, contract,
        member_runner: member_runner,
        issue_fetcher: fn [_issue_id] -> {:ok, [task]} end,
        publisher: fn _status, _summary -> :ok end,
        transitioner: fn -> :ok end,
        update_recipient: self(),
        max_concurrent_agents: 2
      )

    assert {:ok, %{verdict: "pass"}} = result

    assert {:ok, %{verdict: "pass"}} =
             TeamRunner.run_with_contract(task, contract,
               member_runner: member_runner,
               issue_fetcher: fn [_issue_id] -> {:ok, [task]} end,
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end,
               max_concurrent_agents: 2
             )

    assert_received {:team_activity, issue_id, %{agent_id: "coordinator", event: :session_started, timestamp: %DateTime{}}}

    assert issue_id == task.id

    requests =
      trace_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.count(requests, &(&1["method"] == "thread/start")) == 2
    assert Enum.count(requests, &(&1["method"] == "thread/resume")) == 4
    assert Enum.count(requests, &(&1["method"] == "thread/name/set")) == 6

    assert Enum.all?(Enum.filter(requests, &(&1["method"] == "thread/name/set")), fn request ->
             request["params"]["name"] == "[PIN-14 · team] coordinator"
           end)
  end

  test "default coordinator treats a plan-time human decision as a terminal outcome" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-team-runner-human-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "coordinator.trace")
    File.mkdir_p!(test_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    File.write!(
      codex_binary,
      fake_codex_script(
        trace_file,
        ~s({"action":"human","reason":"The declared work requires operator input."})
      )
    )

    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    {task, contract} = team_issue_and_contract(workspace_root)

    assert {:error, {:human_input_required, "The declared work requires operator input."}} =
             TeamRunner.run_with_contract(task, contract,
               member_runner: fn _repository, _member_issue, _opts ->
                 flunk("a human decision must not start implementors")
               end,
               publisher: fn _status, _summary -> :ok end,
               transitioner: fn -> :ok end,
               max_concurrent_agents: 2
             )
  end

  defp fake_codex_script(
         trace_file,
         plan_payload \\ ~s({"waves":[["application","infrastructure"]]})
       ) do
    """
    #!/bin/sh
    set -eu
    while IFS= read -r line; do
      printf '%s\n' "$line" >> "#{trace_file}"
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"id":1,"result":{}}'
          ;;
        *'"method":"thread/start"'*)
          printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-coordinator"},"instructionSources":[]}}'
          ;;
        *'"method":"thread/resume"'*)
          printf '%s\n' '{"id":5,"result":{"thread":{"id":"thread-coordinator"},"instructionSources":[]}}'
          ;;
        *'"method":"thread/name/set"'*)
          printf '%s\n' '{"id":21,"result":{}}'
          ;;
        *'"method":"thread/goal/set"'*)
          printf '%s\n' '{"id":4,"result":{"goal":{"status":"active"}}}'
          ;;
        *'"method":"turn/start"'*)
          artifact=${line#*Write only the decision JSON to }
          artifact=${artifact%% before ending*}
          mkdir -p "$(dirname "$artifact")"
          case "$line" in
            *'Record a global verdict'*) payload='{"verdict":"pass","summary":"Repositories align."}' ;;
            *'completed_wave'*) payload='{"action":"continue"}' ;;
            *) payload='#{plan_payload}' ;;
          esac
          printf '%s' "$payload" > "$artifact"
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-coordinator"}}}'
          printf '%s\n' '{"method":"turn/completed"}'
          ;;
      esac
    done
    """
  end

  defp team_issue_and_contract(workspace_root) do
    registry = %{
      "application" => %{
        "repository_id" => "example/application",
        "workspace" => %{"root" => Path.join(workspace_root, "application")},
        "hooks" => %{}
      },
      "infrastructure" => %{
        "repository_id" => "example/infrastructure",
        "workspace" => %{"root" => Path.join(workspace_root, "infrastructure")},
        "hooks" => %{}
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

    task =
      issue(%{
        labels: ["codex-ready", "codex-team"],
        description: valid_description() <> "\n\n## Team\n" <> team_yaml
      })

    {:ok, contract} = TaskContract.from_issue(task, team_repository_registry: registry)
    {task, contract}
  end
end
