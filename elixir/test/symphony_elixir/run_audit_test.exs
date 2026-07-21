defmodule SymphonyElixir.RunAuditTest do
  use ExUnit.Case, async: true

  import SymphonyElixir.TaskContractFixtures
  alias SymphonyElixir.RunAudit

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-run-audit-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    task = issue()
    RunAudit.start(workspace, task)
    %{workspace: workspace, task: task}
  end

  test "returns an engine proof ID for an observed successful command", context do
    update = %{
      event: :notification,
      payload: %{
        "method" => "item/completed",
        "params" => %{
          "item" => %{
            "type" => "commandExecution",
            "id" => "item-1",
            "command" => "mix test",
            "exitCode" => 0
          }
        }
      }
    }

    assert {:ok, %{event_id: event_id, exit_code: 0}} =
             RunAudit.append_codex_update(context.workspace, context.task, update)

    assert event_id =~ ~r/^proof-[A-Za-z0-9_-]{22}$/

    event =
      context.workspace
      |> RunAudit.paths()
      |> Map.fetch!(:audit_events_path)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["event_id"] == event_id))

    assert event["method"] == "item/completed"
    assert event["command"] == "mix test"
    assert event["exit_code"] == 0
  end

  test "does not mint proof for prose or non-command updates", context do
    assert {:ok, nil} =
             RunAudit.append_codex_update(context.workspace, context.task, %{
               event: :notification,
               payload: %{"method" => "turn/completed", "params" => %{}}
             })
  end

  test "handoff events keep only allowlisted scalar attributes", context do
    assert :ok =
             RunAudit.append_handoff_event(context.workspace, context.task, :handoff_transition_result, %{
               phase: "handoff",
               thread_id: "thread-123",
               plan_digest: String.duplicate("a", 64),
               comment_id: "comment-123",
               marker_key: String.duplicate("b", 64),
               transition_target: "Human Review",
               transition_result: "reconciled",
               status: "completed",
               result: "completed",
               retry: false,
               ambiguous: true,
               rendered_comment_body: "SECRET COMMENT",
               external_payload: %{token: "SECRET TOKEN"},
               evidence_result: %{raw_reasoning: "SECRET REASONING"}
             })

    event =
      context.workspace
      |> RunAudit.paths()
      |> Map.fetch!(:audit_events_path)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> List.last()

    assert event["event"] == "handoff_transition_result"
    assert event["thread_id"] == "thread-123"
    assert event["transition_result"] == "reconciled"
    assert event["ambiguous"] == true
    refute Map.has_key?(event, "rendered_comment_body")
    refute Map.has_key?(event, "external_payload")
    refute Map.has_key?(event, "evidence_result")
    refute File.read!(RunAudit.paths(context.workspace).audit_events_path) =~ "SECRET"
  end
end
