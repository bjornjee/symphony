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
end
