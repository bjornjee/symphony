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

    task = issue()
    File.mkdir_p!(workspace)
    RunAudit.start(workspace, task)
    central_base = central_audit_base(RunAudit.paths(workspace, task))

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(central_base)
    end)

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

  test "aggregates repeated timing slices before selecting the slowest phase and budget overrun",
       context do
    utc = ~U[2026-07-24 00:00:00Z]

    assert :ok =
             RunAudit.record_phase(
               context.workspace,
               context.task,
               "verification",
               time_point(utc, 0),
               time_point(DateTime.add(utc, 200, :second), 200_000),
               "tool"
             )

    assert :ok =
             RunAudit.record_phase(
               context.workspace,
               context.task,
               "verification",
               time_point(DateTime.add(utc, 200, :second), 200_000),
               time_point(DateTime.add(utc, 400, :second), 400_000),
               "subprocess"
             )

    assert :ok =
             RunAudit.record_phase(
               context.workspace,
               context.task,
               "implementation",
               time_point(utc, 0),
               time_point(DateTime.add(utc, 300, :second), 300_000),
               "model"
             )

    assert {:ok, summary} = RunAudit.summary(context.workspace)
    assert summary.slowest_phase == %{phase: "verification", duration_ms: 400_000}

    verification = Enum.find(summary.phases, &(&1["phase"] == "verification"))
    assert verification["attribution_ms"] == %{"subprocess" => 200_000, "tool" => 200_000}
    assert verification["slice_count"] == 2
    refute Map.has_key?(verification, "attribution")
    refute Map.has_key?(verification, "started_at")
    refute Map.has_key?(verification, "ended_at")

    assert summary.budget_overruns == [
             %{phase: "implementation", budget_overrun_ms: 60_000},
             %{phase: "verification", budget_overrun_ms: 100_000}
           ]
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

  test "persists a dashboard-readable audit when the worker workspace is remote", context do
    remote_workspace = Path.join(context.workspace, "remote-worker")
    File.mkdir_p!(remote_workspace)
    RunAudit.start(remote_workspace, context.task, %{worker_host: "worker-a"})
    RunAudit.append(remote_workspace, context.task, :workspace_prepared, %{status: "completed"})

    paths = RunAudit.paths(remote_workspace, context.task)
    refute String.starts_with?(paths.audit_events_path, remote_workspace)
    assert File.exists?(paths.audit_events_path)
    assert {:ok, %{verification_profile: nil}} = RunAudit.summary_path(paths.audit_events_path)

    on_exit(fn -> File.rm_rf(central_audit_base(paths)) end)
  end

  test "preserves central audits across worker attempts", context do
    remote_workspace = Path.join(context.workspace, "shared-remote-workspace")
    File.mkdir_p!(remote_workspace)

    RunAudit.start(remote_workspace, context.task, %{worker_host: "worker-a"})
    RunAudit.append(remote_workspace, context.task, :worker_a_sentinel)
    worker_a_paths = RunAudit.paths(remote_workspace, context.task)

    RunAudit.start(remote_workspace, context.task, %{worker_host: "worker-b"})
    worker_b_paths = RunAudit.paths(remote_workspace, context.task)

    refute worker_a_paths.audit_events_path == worker_b_paths.audit_events_path
    assert File.read!(worker_a_paths.audit_events_path) =~ "worker_a_sentinel"
    assert File.exists?(worker_b_paths.audit_events_path)

    on_exit(fn ->
      File.rm_rf(central_audit_base(worker_a_paths))
    end)
  end

  test "retains only the five most recent central audit attempts", context do
    remote_workspace = Path.join(context.workspace, "retained-remote-workspace")
    File.mkdir_p!(remote_workspace)

    attempts =
      Enum.map(1..7, fn attempt ->
        RunAudit.start(remote_workspace, context.task, %{worker_host: "worker-#{attempt}"})
        path = RunAudit.paths(remote_workspace, context.task).audit_events_path
        RunAudit.finish(remote_workspace, context.task)
        path
      end)

    assert Enum.all?(Enum.take(attempts, -5), &File.exists?/1)
    refute Enum.any?(Enum.take(attempts, 2), &File.exists?/1)

    on_exit(fn ->
      attempts
      |> List.last()
      |> then(&central_audit_base(%{audit_events_path: &1}))
      |> File.rm_rf()
    end)
  end

  test "serializes retention across concurrent central audit attempts", context do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    remote_workspace = Path.join(context.workspace, "concurrent-remote-workspace-#{suffix}")
    File.mkdir_p!(remote_workspace)

    paths =
      1..40
      |> Task.async_stream(
        fn attempt ->
          RunAudit.start(remote_workspace, context.task, %{worker_host: "worker-#{attempt}"})
          paths = RunAudit.paths(remote_workspace, context.task)
          RunAudit.finish(remote_workspace, context.task)
          paths
        end,
        max_concurrency: 40,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, path} -> path end)

    base = paths |> hd() |> central_audit_base()
    on_exit(fn -> File.rm_rf(base) end)

    attempts = base |> Path.join("attempts") |> File.ls!() |> MapSet.new()
    manifest = base |> Path.join("attempts.json") |> File.read!() |> Jason.decode!() |> MapSet.new()

    assert MapSet.size(attempts) <= 5
    assert attempts == manifest
  end

  test "keeps an active attempt listed while newer attempts finish", context do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    remote_workspace = Path.join(context.workspace, "active-remote-workspace-#{suffix}")
    File.mkdir_p!(remote_workspace)
    parent = self()

    active =
      Task.async(fn ->
        RunAudit.start(remote_workspace, context.task, %{worker_host: "active-worker"})
        paths = RunAudit.paths(remote_workspace, context.task)
        send(parent, {:active_started, paths})

        receive do
          :append -> RunAudit.append(remote_workspace, context.task, :active_sentinel)
        end

        send(parent, :active_appended)

        receive do
          :finish -> RunAudit.finish(remote_workspace, context.task)
        end
      end)

    assert_receive {:active_started, active_paths}
    base = central_audit_base(active_paths)
    on_exit(fn -> File.rm_rf(base) end)

    Enum.each(1..5, fn attempt ->
      RunAudit.start(remote_workspace, context.task, %{worker_host: "newer-#{attempt}"})
      RunAudit.finish(remote_workspace, context.task)
    end)

    manifest = base |> Path.join("attempts.json") |> File.read!() |> Jason.decode!()
    active_id = active_paths.audit_events_path |> Path.dirname() |> Path.basename()
    assert File.exists?(active_paths.audit_events_path)
    assert active_id in manifest

    send(active.pid, :append)
    assert_receive :active_appended
    assert File.read!(active_paths.audit_events_path) =~ "active_sentinel"

    send(active.pid, :finish)
    Task.await(active)
  end

  test "never evicts active attempts when more than five overlap", context do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    remote_workspace = Path.join(context.workspace, "overlapping-remote-workspace-#{suffix}")
    File.mkdir_p!(remote_workspace)

    paths =
      Enum.map(1..6, fn attempt ->
        RunAudit.start(remote_workspace, context.task, %{worker_host: "worker-#{attempt}"})
        RunAudit.paths(remote_workspace, context.task)
      end)

    base = paths |> hd() |> central_audit_base()
    on_exit(fn -> File.rm_rf(base) end)

    manifest = base |> Path.join("attempts.json") |> File.read!() |> Jason.decode!()
    active_ids = Enum.map(paths, &(&1.audit_events_path |> Path.dirname() |> Path.basename()))

    assert Enum.all?(paths, &File.exists?(&1.audit_events_path))
    assert Enum.all?(active_ids, &(&1 in manifest))
  end

  test "reconciles safe on-disk attempts when the manifest is malformed", context do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    remote_workspace = Path.join(context.workspace, "reconciled-remote-workspace-#{suffix}")
    File.mkdir_p!(remote_workspace)

    RunAudit.start(remote_workspace, context.task, %{worker_host: "worker-a"})
    paths = RunAudit.paths(remote_workspace, context.task)
    base = central_audit_base(paths)
    orphan_id = "safe_orphan_attempt"
    orphan = Path.join([base, "attempts", orphan_id])
    File.mkdir_p!(orphan)
    File.write!(Path.join(orphan, "run-audit.jsonl"), "{}\n")
    File.write!(Path.join(base, "attempts.json"), "{not-json")

    RunAudit.start(remote_workspace, context.task, %{worker_host: "worker-b"})

    on_exit(fn -> File.rm_rf(base) end)

    manifest = base |> Path.join("attempts.json") |> File.read!() |> Jason.decode!()
    assert orphan_id in manifest
    assert File.exists?(Path.join(orphan, "run-audit.jsonl"))
  end

  test "treats markers without a live registered owner as completed attempts", context do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    remote_workspace = Path.join(context.workspace, "stale-remote-workspace-#{suffix}")
    File.mkdir_p!(remote_workspace)

    RunAudit.start(remote_workspace, context.task, %{worker_host: "live-worker"})
    paths = RunAudit.paths(remote_workspace, context.task)
    base = central_audit_base(paths)

    stale_ids =
      Enum.map(1..6, fn attempt ->
        id = "stale_attempt_#{attempt}"
        directory = Path.join([base, "attempts", id])
        File.mkdir_p!(directory)
        File.touch!(Path.join(directory, ".active"))
        File.write!(Path.join(directory, "run-audit.jsonl"), "{}\n")
        id
      end)

    File.write!(Path.join(base, "attempts.json"), Jason.encode!(stale_ids))
    RunAudit.start(remote_workspace, context.task, %{worker_host: "next-live-worker"})

    on_exit(fn -> File.rm_rf(base) end)

    manifest = base |> Path.join("attempts.json") |> File.read!() |> Jason.decode!()
    assert length(Enum.filter(stale_ids, &(&1 in manifest))) == 5
    refute File.exists?(Path.join([base, "attempts", hd(stale_ids)]))
  end

  test "compacts noisy history before the audit exceeds its summary bound", context do
    path = RunAudit.paths(context.workspace).audit_events_path
    filler = Jason.encode!(%{"event" => "agent_message", "detail" => String.duplicate("x", 180)}) <> "\n"
    File.write!(path, :binary.copy(filler, div(4_194_304, byte_size(filler))))

    RunAudit.append(context.workspace, context.task, :verification_profile_selected, %{
      verification_profile: "Full"
    })

    assert File.stat!(path).size <= 4_194_304
    assert {:ok, %{verification_profile: "Full"}} = RunAudit.summary(context.workspace)
  end

  test "compaction preserves aggregate diagnostics when retained events exceed the bound", context do
    path = RunAudit.paths(context.workspace).audit_events_path

    profile =
      Jason.encode!(%{
        "event" => "verification_profile_selected",
        "verification_profile" => "Full"
      })

    phases =
      Enum.map_join(1..60, "\n", fn index ->
        Jason.encode!(%{
          "event" => "phase_timing",
          "phase" => if(index == 1, do: "planning", else: "verification"),
          "duration_ms" => if(index == 1, do: 99_999, else: index),
          "budget_overrun_ms" => if(index == 1, do: 50_000, else: nil),
          "detail" => String.duplicate("x", 80_000)
        })
      end)

    File.write!(path, profile <> "\n" <> phases <> "\n")

    RunAudit.append(context.workspace, context.task, :proof_cache_result, %{
      cache: "proof",
      cache_status: "hit"
    })

    assert File.stat!(path).size <= 4_194_304

    assert {:ok, summary} = RunAudit.summary(context.workspace)
    assert summary.verification_profile == "Full"
    assert summary.cache.proof.hits == 1
    assert summary.slowest_phase == %{phase: "planning", duration_ms: 99_999}
    assert summary.budget_overruns == [%{phase: "planning", budget_overrun_ms: 50_000}]
  end

  test "compaction pins the first useful edit outside the bounded activity tail", context do
    path = RunAudit.paths(context.workspace).audit_events_path

    first_edit =
      Jason.encode!(%{
        "event" => "first_useful_edit",
        "timestamp" => "2026-07-24T08:00:00Z",
        "phase" => "implementation",
        "status" => "completed"
      })

    noise =
      Enum.map_join(1..60, "\n", fn index ->
        Jason.encode!(%{
          "event" => "proof_completed",
          "timestamp" => "2026-07-24T08:00:#{index}Z",
          "detail" => String.duplicate("x", 80_000)
        })
      end)

    File.write!(path, first_edit <> "\n" <> noise <> "\n")

    RunAudit.append(context.workspace, context.task, :proof_cache_result, %{
      cache: "proof",
      cache_status: "hit"
    })

    assert Enum.any?(events(context.workspace), fn event ->
             event["event"] == "first_useful_edit" and
               event["timestamp"] == "2026-07-24T08:00:00Z"
           end)
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

  defp central_audit_base(paths) do
    paths.audit_events_path
    |> Path.dirname()
    |> Path.dirname()
    |> Path.dirname()
  end
end
