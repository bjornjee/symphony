defmodule SymphonyElixir.PlanPinningIntegrationTest do
  use SymphonyElixir.TestSupport

  import SymphonyElixir.TaskContractFixtures
  alias SymphonyElixir.Linear.TaskContract

  test "invalid task contract stops before claim or worker dispatch" do
    task = issue(%{description: "## Goal\nOnly a goal."})
    state = %Orchestrator.State{}
    recipient = self()

    issue_fetcher = fn [issue_id] -> {:ok, [%{task | id: issue_id}]} end

    claim = fn claimed_issue ->
      send(recipient, {:claimed, claimed_issue.id})
      {:ok, claimed_issue}
    end

    dispatch = fn current_state, dispatched_issue, _contract, _attempt, _worker_host ->
      send(recipient, {:dispatched, dispatched_issue.id})
      current_state
    end

    assert ^state =
             Orchestrator.dispatch_issue_for_test(state, task,
               issue_fetcher: issue_fetcher,
               claim: claim,
               dispatch: dispatch
             )

    refute_receive {:claimed, _issue_id}
    refute_receive {:dispatched, _issue_id}
  end

  test "invalid task contract starts no workspace hook" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-invalid-contract-#{System.unique_integer([:positive, :monotonic])}"
      )

    hook_marker = Path.join(root, "after-create-ran")
    workspace_root = Path.join(root, "workspaces")

    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_after_create: "touch #{hook_marker}"
    )

    task = issue(%{identifier: "PIN-INVALID", description: "## Goal\nOnly a goal."})

    assert_raise RuntimeError, ~r/Task contract invalid/, fn -> AgentRunner.run(task) end
    refute File.exists?(hook_marker)
    refute File.exists?(Path.join(workspace_root, "PIN-INVALID"))
  end

  test "continuation rejects a changed plan digest" do
    task = issue(%{state: "In Progress"})
    assert {:ok, contract} = TaskContract.from_issue(task)
    changed = %{task | title: "Changed after approval"}
    fetcher = fn ["issue-1"] -> {:ok, [changed]} end

    assert {:error, {:plan_drift, expected, actual}} =
             AgentRunner.continue_with_issue_for_test(task, contract, fetcher)

    assert expected == contract.digest
    refute actual == expected
  end
end
