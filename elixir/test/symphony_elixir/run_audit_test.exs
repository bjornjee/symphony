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

  test "records machine-readable phase timing with attribution and budget overrun", context do
    started_at = time_point(~U[2026-07-24 08:00:00.000Z], 1_000)
    ended_at = time_point(~U[2026-07-24 08:00:02.250Z], 3_250)

    assert :ok =
             RunAudit.record_phase(
               context.workspace,
               context.task,
               "context_loading",
               started_at,
               ended_at,
               "tool",
               %{budget_ms: 2_000}
             )

    event = List.last(events(context.workspace))

    assert event["event"] == "phase_timing"
    assert event["phase"] == "context_loading"
    assert event["started_at"] == "2026-07-24T08:00:00.000Z"
    assert event["ended_at"] == "2026-07-24T08:00:02.250Z"
    assert event["duration_ms"] == 2_250
    assert event["attribution"] == "tool"
    assert event["budget_ms"] == 2_000
    assert event["budget_overrun_ms"] == 250
  end

  test "uses monotonic elapsed time when the wall clock moves backwards", context do
    assert :ok =
             RunAudit.record_phase(
               context.workspace,
               context.task,
               "planning",
               time_point(~U[2026-07-24 08:00:02Z], 10_000),
               time_point(~U[2026-07-24 08:00:01Z], 10_750),
               "model"
             )

    assert %{
             "started_at" => "2026-07-24T08:00:02Z",
             "ended_at" => "2026-07-24T08:00:01Z",
             "duration_ms" => 750
           } = List.last(events(context.workspace))
  end

  test "requires a reason for external wait timing", context do
    assert {:error, :external_wait_reason_required} =
             RunAudit.record_phase(
               context.workspace,
               context.task,
               "external_wait",
               time_point(~U[2026-07-24 08:00:00Z], 1_000),
               time_point(~U[2026-07-24 08:00:01Z], 2_000),
               "external",
               %{}
             )

    assert :ok =
             RunAudit.record_phase(
               context.workspace,
               context.task,
               "external_wait",
               time_point(~U[2026-07-24 08:00:00Z], 1_000),
               time_point(~U[2026-07-24 08:00:01Z], 2_000),
               "external",
               %{reason: "waiting for GitHub checks"}
             )
  end

  test "summarizes slowest phase, cache outcomes, profile, and overruns", context do
    assert :ok =
             RunAudit.record_phase(
               context.workspace,
               context.task,
               "planning",
               time_point(~U[2026-07-24 08:00:00Z], 1_000),
               time_point(~U[2026-07-24 08:00:03Z], 4_000),
               "model",
               %{budget_ms: 2_000}
             )

    assert :ok =
             RunAudit.record_phase(
               context.workspace,
               context.task,
               "verification",
               time_point(~U[2026-07-24 08:00:03Z], 4_000),
               time_point(~U[2026-07-24 08:00:04Z], 5_000),
               "subprocess"
             )

    RunAudit.append(context.workspace, context.task, :verification_profile_selected, %{
      phase: "planning",
      verification_profile: "Targeted"
    })

    RunAudit.append(context.workspace, context.task, :context_cache_result, %{
      phase: "context_loading",
      cache: "context",
      cache_status: "hit"
    })

    RunAudit.append(context.workspace, context.task, :proof_cache_result, %{
      phase: "verification",
      cache: "proof",
      cache_status: "miss"
    })

    assert {:ok, summary} = RunAudit.summary(context.workspace)
    assert summary.verification_profile == "Targeted"

    assert summary.cache == %{
             context: %{hits: 1, misses: 0},
             proof: %{hits: 0, misses: 1}
           }

    assert summary.slowest_phase == %{phase: "planning", duration_ms: 3_000}
    assert summary.budget_overruns == [%{phase: "planning", budget_overrun_ms: 1_000}]
  end

  test "records the first completed file change as the first useful edit", context do
    started = %{
      event: :notification,
      payload: %{
        "method" => "item/started",
        "params" => %{"item" => %{"type" => "fileChange", "status" => "inProgress"}}
      }
    }

    completed = %{
      event: :notification,
      payload: %{
        "method" => "item/completed",
        "params" => %{"item" => %{"type" => "fileChange", "status" => "completed"}}
      }
    }

    assert {:ok, nil} = RunAudit.append_codex_update(context.workspace, context.task, started)
    assert [] == Enum.filter(events(context.workspace), &(&1["event"] == "first_useful_edit"))

    assert {:ok, nil} = RunAudit.append_codex_update(context.workspace, context.task, completed)
    assert {:ok, nil} = RunAudit.append_codex_update(context.workspace, context.task, completed)

    first_edit_events =
      Enum.filter(events(context.workspace), fn event ->
        event["event"] == "first_useful_edit" and
          event["phase"] == "implementation" and
          event["status"] == "completed"
      end)

    assert length(first_edit_events) == 1
  end

  test "applies runtime phase budgets when no override is supplied", context do
    assert :ok =
             RunAudit.record_phase(
               context.workspace,
               context.task,
               "context_loading",
               time_point(~U[2026-07-24 08:00:00Z], 1_000),
               time_point(~U[2026-07-24 08:01:01Z], 62_000),
               "tool"
             )

    assert %{
             "budget_ms" => 60_000,
             "budget_overrun_ms" => 1_000
           } = List.last(events(context.workspace))
  end

  test "appends a compact run summary for bounded dashboard reads", context do
    assert :ok =
             RunAudit.record_phase(
               context.workspace,
               context.task,
               "verification",
               time_point(~U[2026-07-24 08:00:00Z], 1_000),
               time_point(~U[2026-07-24 08:00:02Z], 3_000),
               "subprocess",
               %{budget_ms: 1_500}
             )

    RunAudit.append(context.workspace, context.task, :verification_profile_selected, %{
      verification_profile: "Full"
    })

    RunAudit.append(context.workspace, context.task, :proof_cache_result, %{
      cache: "proof",
      cache_status: "hit"
    })

    assert :ok = RunAudit.finish(context.workspace, context.task)

    assert %{
             "event" => "run_summary",
             "verification_profile" => "Full",
             "context_cache_hits" => 0,
             "context_cache_misses" => 0,
             "proof_cache_hits" => 1,
             "proof_cache_misses" => 0,
             "slowest_phase" => "verification",
             "slowest_phase_duration_ms" => 2_000,
             "budget_overrun_count" => 1,
             "max_budget_overrun_ms" => 500
           } = List.last(events(context.workspace))
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

  defp events(workspace) do
    workspace
    |> RunAudit.paths()
    |> Map.fetch!(:audit_events_path)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp time_point(utc, monotonic_ms), do: %{utc: utc, monotonic_ms: monotonic_ms}
end
