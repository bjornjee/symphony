defmodule SymphonyElixir.HumanReviewBlockerTest do
  use ExUnit.Case

  alias SymphonyElixir.HumanReviewBlocker
  alias SymphonyElixir.Linear.Issue

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

  test "publishes, reads back, transitions, and reuses one deterministic blocker" do
    issue = %Issue{id: "issue-1", identifier: "PIN-1", title: "Blocked", state: "In Progress"}
    opts = [tracker: FakeTracker, handoff_state: "Human Review"]

    assert {:ok, comment_id} = HumanReviewBlocker.publish(issue, ["contract", "plan"], "## Agent Blocked", opts)
    assert {:ok, ^comment_id} = HumanReviewBlocker.publish(issue, ["contract", "plan"], "## Agent Blocked", opts)
    assert Process.get({FakeTracker, :state}) == "Human Review"
  end
end
