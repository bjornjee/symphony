defmodule SymphonyElixir.TeamExecutionPublisherTest do
  use SymphonyElixir.TestSupport

  import SymphonyElixir.TaskContractFixtures

  alias SymphonyElixir.TeamExecutionPublisher
  alias SymphonyElixir.Tracker.Memory

  defmodule FetchErrorTracker do
    def fetch_comment(_issue_id, _comment_id), do: {:error, :offline}
    def create_comment(_issue_id, _comment_id, _body), do: :ok
    def update_comment(_comment_id, _body), do: :ok
  end

  defmodule MissingReadbackTracker do
    def fetch_comment(_issue_id, _comment_id), do: {:ok, nil}
    def create_comment(_issue_id, _comment_id, _body), do: :ok
    def update_comment(_comment_id, _body), do: :ok
  end

  test "updates one deterministic execution comment across lifecycle states" do
    task = issue()
    comment_id = TeamExecutionPublisher.comment_id(task)

    assert :ok =
             TeamExecutionPublisher.publish(
               task,
               "Started",
               %{repositories: ["application", "infrastructure"]},
               tracker: Memory
             )

    assert {:ok, %{id: ^comment_id, body: started_body}} = Memory.fetch_comment(task.id, comment_id)
    assert started_body =~ "Status: **Started**"

    assert :ok =
             TeamExecutionPublisher.publish(
               task,
               "Finished",
               %{
                 members: %{
                   "application" => %{pull_request_url: "https://github.com/example/app/pull/1"},
                   "infrastructure" => %{pull_request_url: "https://github.com/example/infra/pull/2"}
                 }
               },
               tracker: Memory
             )

    assert {:ok, %{id: ^comment_id, body: finished_body}} = Memory.fetch_comment(task.id, comment_id)
    assert finished_body =~ "Status: **Finished**"
    assert finished_body =~ "https://github.com/example/app/pull/1"

    assert :ok = TeamExecutionPublisher.publish(task, "Finished", %{members: %{}}, tracker: Memory)
    assert :ok = TeamExecutionPublisher.publish(task, "Finished", %{members: %{}}, tracker: Memory)

    assert {:ok, %{id: ^comment_id}} = Memory.fetch_comment(task.id, comment_id)
  end

  test "fails closed when Linear fetch or readback cannot confirm the execution comment" do
    task = issue()

    assert {:error, :offline} =
             TeamExecutionPublisher.publish(task, "Started", %{}, tracker: FetchErrorTracker)

    assert {:error, :team_execution_comment_missing} =
             TeamExecutionPublisher.publish(task, "Started", %{}, tracker: MissingReadbackTracker)
  end
end
