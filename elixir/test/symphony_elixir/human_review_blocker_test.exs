defmodule SymphonyElixir.HumanReviewBlockerTest do
  use ExUnit.Case

  alias SymphonyElixir.{
    ExecutionControl,
    ExecutionLedger,
    HumanReviewBlocker,
    PlanningArtifact
  }

  alias SymphonyElixir.Linear.{Issue, TaskContract}

  defmodule FakeTracker do
    def fetch_comment(_issue_id, comment_id) do
      case Process.get({__MODULE__, :comment}) do
        nil -> {:ok, nil}
        body -> {:ok, %{id: comment_id, body: body}}
      end
    end

    def create_comment(_issue_id, _comment_id, body) do
      Process.put({__MODULE__, :comment}, body)
      :ok
    end

    def update_issue_state(_issue_id, state) do
      Process.put({__MODULE__, :state}, state)
      :ok
    end

    def fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{id: issue_id, identifier: "PIN-1", title: "Blocked", state: Process.get({__MODULE__, :state})}]}
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "human-review-blocker-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:symphony_elixir, :execution_state_root, root)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :execution_state_root)
      File.rm_rf(root)
    end)

    :ok
  end

  test "publishes, reads back, transitions, and reuses one deterministic blocker" do
    issue = %Issue{id: "issue-1", identifier: "PIN-1", title: "Blocked", state: "In Progress"}
    opts = [tracker: FakeTracker, handoff_state: "Human Review"]
    Process.put({FakeTracker, :state}, "In Progress")

    assert {:ok, comment_id} = HumanReviewBlocker.publish(issue, ["contract", "plan"], "## Agent Blocked", opts)
    assert {:ok, ^comment_id} = HumanReviewBlocker.publish(issue, ["contract", "plan"], "## Agent Blocked", opts)
    assert Process.get({FakeTracker, :state}) == "Human Review"
  end

  test "does not overwrite a state advanced by a human" do
    issue = %Issue{id: "issue-1", identifier: "PIN-1", title: "Blocked", state: "In Progress"}
    opts = [tracker: FakeTracker, handoff_state: "Human Review"]
    Process.put({FakeTracker, :state}, "In Progress")

    assert {:ok, _comment_id} =
             HumanReviewBlocker.publish(
               issue,
               ["contract", "plan"],
               "## Agent Blocked",
               opts
             )

    Process.put({FakeTracker, :state}, "Done")

    assert {:error, {:human_review_state_source_mismatch, "In Progress", "Done", "Human Review"}} =
             HumanReviewBlocker.publish(
               issue,
               ["contract", "plan"],
               "## Agent Blocked",
               opts
             )

    assert Process.get({FakeTracker, :state}) == "Done"
  end

  test "proof exhaustion produces one terminal Human Review completion" do
    issue = %Issue{
      id: "issue-1",
      identifier: "PIN-1",
      title: "Blocked",
      state: "In Progress",
      labels: ["codex-ready"]
    }

    contract = %TaskContract{digest: String.duplicate("a", 64)}
    plan = %{"plan_digest" => String.duplicate("b", 64)}
    proof = %{"id" => "repository-test"}

    receipt = %{
      "attempt" => 3,
      "expected_exit" => "success",
      "exit_status" => 1,
      "runner_error" => nil,
      "freshness_error" => nil
    }

    opts = [tracker: FakeTracker, handoff_state: "Human Review"]
    ledger_key = "proof-exhaustion-test"
    Process.put({FakeTracker, :state}, "In Progress")

    for attempt <- 1..3 do
      {:ok, _persisted} =
        ExecutionLedger.create(
          ledger_key,
          "proof",
          "repository-test-#{attempt}",
          Map.merge(receipt, %{
            "attempt" => attempt,
            "passed" => false,
            "proof_id" => proof["id"],
            "proof_digest" => PlanningArtifact.digest(proof)
          })
        )
    end

    assert {:ok, completion} =
             ExecutionControl.block_on_exhausted_proof(
               %{"candidate" => %{"proofs" => [proof]}, "plan_digest" => plan["plan_digest"]},
               ledger_key,
               issue,
               contract,
               opts
             )

    assert completion.outcome == :human_review_required
    assert completion.continuation == :done
    refute completion.issue_active
    refute completion.issue_routable
    assert completion.issue_state == "Human Review"
    assert Process.get({FakeTracker, :comment}) =~ "failed all three approved attempts"
    assert Process.get({FakeTracker, :state}) == "Human Review"

    assert {:ok, repeated} =
             ExecutionControl.block_on_exhausted_proof(
               %{"candidate" => %{"proofs" => [proof]}, "plan_digest" => plan["plan_digest"]},
               ledger_key,
               issue,
               contract,
               opts
             )

    assert repeated.blocker_comment_id == completion.blocker_comment_id
  end
end
