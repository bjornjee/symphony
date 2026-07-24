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
             revision: 3,
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
    assert report.evidence.expected_diff == "PIN-28 commit 41808f55"
    assert report.evidence.verification == "deterministic lifecycle proof receipts"
    assert report.evidence.review == "deterministic lifecycle review"
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
               is_binary(sample.baseline.lifecycle.review["receipt_digest"]) and
               is_binary(sample.baseline.lifecycle.publication.receipt_digest) and
               is_binary(sample.baseline.lifecycle.handoff["artifact_digest"]) and
               non_empty_handoff?(sample.baseline.lifecycle.handoff) and
               Map.has_key?(sample.baseline.phases, :verification_ms) and
               Map.has_key?(sample.candidate.phases, :handoff_ms) and
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

  test "rejects fewer than ten controlled runs" do
    assert_raise ArgumentError, ~r/at least 10/, fn ->
      Pin28Benchmark.run(runs: 9, observation_delay_ms: 0)
    end
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
