defmodule SymphonyElixir.Pin28BenchmarkTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Symphony.Benchmark.Pin28, as: Pin28Task
  alias SymphonyElixir.Pin28Benchmark

  test "ten controlled runs improve latency without reducing completion accuracy" do
    report = Pin28Benchmark.run(runs: 10, observation_delay_ms: 50, fixed_overhead_ms: 30)

    assert report.run_count == 10
    assert byte_size(report.repository_revision) == 40
    assert byte_size(report.task_contract_digest) == 64
    assert is_binary(report.environment.elixir)

    assert report.model_configuration == %{
             kind: "deterministic-agent-replay",
             revision: 5,
             live_model: false
           }

    assert report.required_artifacts.verification == [
             "make symphony-workflow",
             "make symphony-workflow-check",
             "mise exec -- make all"
           ]

    assert report.required_artifacts.review_checks == ["correctness", "security", "convention", "scope"]
    assert report.required_artifacts.handoff_fields == ["summary", "verification", "reviewer_action", "audit"]
    assert report.expected_diff == ["Makefile", "docs/symphony-linear-setup.md"]

    assert report.evidence.expected_diff ==
             "content-addressed two-file fixture derived from PIN-28 task shape"

    assert report.evidence.verification == "real fixture commands with deterministic lifecycle proof receipts"
    assert report.evidence.review == "deterministic review of the observed fixture content digest"
    assert report.evidence.handoff == "validated lifecycle publication and handoff"
    assert report.baseline.median_end_to_end_ms > report.candidate.median_end_to_end_ms
    assert report.improvement_percent >= 40.0
    assert report.candidate.median_end_to_end_ms <= 600_000
    assert report.candidate.median_first_useful_edit_ms <= 240_000
    assert report.baseline.completion_accuracy == 1.0
    assert report.candidate.completion_accuracy == report.baseline.completion_accuracy

    assert Enum.all?(report.samples, fn sample ->
             Enum.all?(sample.baseline.accuracy, fn {_name, passed} -> passed end) and
               Enum.all?(sample.candidate.accuracy, fn {_name, passed} -> passed end) and
               sample.baseline.lifecycle.planning.passed and
               sample.baseline.lifecycle.publication.passed and
               Enum.all?(sample.baseline.lifecycle.verification, &is_binary(&1.receipt_digest)) and
               Enum.all?(sample.candidate.lifecycle.verification, &is_binary(&1.receipt_digest)) and
               is_binary(sample.baseline.lifecycle.review["receipt_digest"]) and
               is_binary(sample.candidate.lifecycle.review["receipt_digest"]) and
               is_binary(sample.baseline.lifecycle.publication.receipt_digest) and
               is_binary(sample.candidate.lifecycle.publication.receipt_digest) and
               is_binary(sample.baseline.lifecycle.handoff["artifact_digest"]) and
               is_binary(sample.candidate.lifecycle.handoff["artifact_digest"]) and
               sample.baseline.lifecycle.implementation.changed_paths == report.expected_diff and
               sample.candidate.lifecycle.implementation.changed_paths == report.expected_diff and
               sample.baseline.lifecycle.workspace_id != sample.candidate.lifecycle.workspace_id and
               not sample.baseline.lifecycle.proofs_reused and
               sample.candidate.lifecycle.proofs_reused and
               Enum.all?(sample.baseline.lifecycle.verification, &(&1.cache_status == "miss")) and
               Enum.all?(sample.candidate.lifecycle.verification, &(&1.cache_status == "hit")) and
               non_empty_handoff?(sample.baseline.lifecycle.handoff) and
               Map.has_key?(sample.baseline.phases, :verification_ms) and
               Map.has_key?(sample.candidate.phases, :handoff_ms) and
               sample.baseline.first_useful_edit_ms >=
                 sample.baseline.phases.workspace_bootstrap_ms +
                   sample.baseline.phases.context_loading_ms +
                   sample.baseline.phases.planning_ms and
               sample.candidate.first_useful_edit_ms >=
                 sample.candidate.phases.workspace_bootstrap_ms +
                   sample.candidate.phases.context_loading_ms +
                   sample.candidate.phases.planning_ms and
               sample.baseline.end_to_end_ms >=
                 Enum.sum(Map.values(sample.baseline.phases)) and
               sample.candidate.end_to_end_ms >=
                 Enum.sum(Map.values(sample.candidate.phases))
           end)

    assert report.candidate.p95_end_to_end_ms >= report.candidate.median_end_to_end_ms
    assert report.thresholds_passed
  end

  test "fails completion accuracy when observed lifecycle evidence is incomplete" do
    observer = fn ->
      %{changed_paths: [], commit_message: "", commit_sha: nil}
    end

    report =
      Pin28Benchmark.run(
        runs: 10,
        observation_delay_ms: 1,
        fixed_overhead_ms: 1,
        artifact_observer: observer
      )

    assert report.baseline.completion_accuracy == 0.0
    assert report.candidate.completion_accuracy == 0.0
    refute report.thresholds_passed
  end

  test "does not report a first useful edit when the implementation writer makes no change" do
    report =
      Pin28Benchmark.run(
        runs: 10,
        observation_delay_ms: 1,
        fixed_overhead_ms: 1,
        implementation_writer: fn _workspace -> :ok end
      )

    assert report.baseline.median_first_useful_edit_ms == 600_001
    assert report.candidate.median_first_useful_edit_ms == 600_001
    assert report.baseline.completion_accuracy == 0.0
    assert report.candidate.completion_accuracy == 0.0
    refute report.thresholds_passed
  end

  test "fails expected diff and review accuracy when fixture content changes on the approved paths" do
    mutator = fn workspace ->
      File.write!(
        Path.join(workspace, "docs/symphony-linear-setup.md"),
        "\nUnrelated same-path content.\n",
        [:append]
      )
    end

    report =
      Pin28Benchmark.run(
        runs: 10,
        observation_delay_ms: 1,
        fixed_overhead_ms: 1,
        implementation_mutator: mutator
      )

    assert report.baseline.completion_accuracy == 0.0
    assert report.candidate.completion_accuracy == 0.0

    assert Enum.all?(report.samples, fn sample ->
             refute sample.baseline.accuracy.expected_diff
             refute sample.baseline.accuracy.review
             refute sample.candidate.accuracy.expected_diff
             refute sample.candidate.accuracy.review
             true
           end)

    refute report.thresholds_passed
  end

  test "fails closed when required verification commands fail" do
    executor = fn _directory, _command, _opts ->
      {:ok, %{exit_status: 1, stdout: "", stderr: "failed"}}
    end

    report =
      Pin28Benchmark.run(
        runs: 10,
        observation_delay_ms: 1,
        fixed_overhead_ms: 1,
        command_executor: executor
      )

    assert report.baseline.completion_accuracy == 0.0
    assert report.candidate.completion_accuracy == 0.0
    refute report.thresholds_passed
  end

  test "fails closed when immutable lifecycle evidence is missing" do
    mutator = fn lifecycle ->
      update_in(lifecycle, [:review], &Map.drop(&1, ["security"]))
    end

    report =
      Pin28Benchmark.run(
        runs: 10,
        observation_delay_ms: 1,
        fixed_overhead_ms: 1,
        lifecycle_mutator: mutator
      )

    assert report.baseline.completion_accuracy == 0.0
    assert report.candidate.completion_accuracy == 0.0
    refute report.thresholds_passed
  end

  test "reports review adapter failures as failed accuracy instead of crashing" do
    report =
      Pin28Benchmark.run(
        runs: 10,
        observation_delay_ms: 1,
        fixed_overhead_ms: 1,
        review_requester: fn _lifecycle -> {:error, :forced_review_failure} end
      )

    assert report.baseline.completion_accuracy == 0.0
    assert report.candidate.completion_accuracy == 0.0
    refute report.thresholds_passed
  end

  test "fails closed when validated handoff evidence is missing" do
    mutator = fn lifecycle ->
      update_in(lifecycle, [:handoff], &Map.delete(&1, "artifact_digest"))
    end

    report =
      Pin28Benchmark.run(
        runs: 10,
        observation_delay_ms: 1,
        fixed_overhead_ms: 1,
        lifecycle_mutator: mutator
      )

    assert report.baseline.completion_accuracy == 0.0
    assert report.candidate.completion_accuracy == 0.0
    refute report.thresholds_passed
  end

  test "fails closed when lifecycle digests are not bound to trusted evidence" do
    mutator = fn lifecycle ->
      lifecycle
      |> put_in([:review, "receipt_digest"], String.duplicate("0", 64))
      |> put_in([:publication, :receipt_digest], String.duplicate("1", 64))
      |> put_in([:handoff, "artifact_digest"], String.duplicate("2", 64))
    end

    report =
      Pin28Benchmark.run(
        runs: 10,
        observation_delay_ms: 1,
        fixed_overhead_ms: 1,
        lifecycle_mutator: mutator
      )

    assert report.baseline.completion_accuracy == 0.0
    assert report.candidate.completion_accuracy == 0.0
    refute report.thresholds_passed
  end

  test "rejects fewer than ten controlled runs" do
    assert_raise ArgumentError, ~r/at least 10/, fn ->
      Pin28Benchmark.run(runs: 9, observation_delay_ms: 0)
    end
  end

  test "retries atomic temporary directory creation after a stale-name collision" do
    parent =
      Path.join(
        System.tmp_dir!(),
        "pin28-root-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(parent, "collision"))
    File.write!(Path.join(parent, "collision/sentinel"), "preserve")
    {:ok, names} = Agent.start_link(fn -> ["collision", "fresh"] end)

    name_generator = fn ->
      Agent.get_and_update(names, fn [name | rest] -> {name, rest} end)
    end

    on_exit(fn ->
      if Process.alive?(names), do: Agent.stop(names)
      File.rm_rf(parent)
    end)

    report =
      Pin28Benchmark.run(
        runs: 10,
        observation_delay_ms: 1,
        fixed_overhead_ms: 1,
        temporary_root_parent: parent,
        root_name_generator: name_generator
      )

    assert report.run_count == 10
    assert report.baseline.completion_accuracy == 1.0
    assert report.candidate.completion_accuracy == 1.0
    assert File.read!(Path.join(parent, "collision/sentinel")) == "preserve"
    assert Agent.get(names, & &1) == []
  end

  test "Mix task prints the machine-readable benchmark report" do
    output =
      capture_io(fn ->
        Pin28Task.run([
          "--runs",
          "10",
          "--observation-delay-ms",
          "1",
          "--fixed-overhead-ms",
          "1"
        ])
      end)

    assert Jason.decode!(output)["run_count"] == 10
  end

  test "Mix task rejects invalid options and failed checked thresholds" do
    assert_raise Mix.Error, ~r/invalid benchmark options/, fn ->
      Pin28Task.run(["--unknown"])
    end

    assert_raise Mix.Error, ~r/thresholds failed/, fn ->
      capture_io(fn ->
        Pin28Task.run([
          "--runs",
          "10",
          "--observation-delay-ms",
          "0",
          "--fixed-overhead-ms",
          "10",
          "--check"
        ])
      end)
    end
  end

  defp non_empty_handoff?(handoff) do
    Enum.all?(["summary", "verification", "reviewer_action", "audit"], fn field ->
      is_binary(handoff[field]) and String.trim(handoff[field]) != ""
    end)
  end
end
