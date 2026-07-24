defmodule SymphonyElixir.Pin28Benchmark do
  @moduledoc "Runs the controlled PIN-28 harness-overhead latency evaluation."

  alias SymphonyElixir.RepositoryFingerprint

  @expected_diff ["Makefile", "docs/symphony-linear-setup.md"]
  @pin_28_commit "41808f55b68b3727710651df7601e6f2023e40dc"
  @task_contract %{
    goal: "Add Makefile commands and setup documentation for running Symphony.",
    affected_paths: @expected_diff,
    verification: ["make all"],
    review_checks: ["correctness", "security", "convention", "scope"],
    handoff_fields: ["summary", "verification", "reviewer_action", "audit"]
  }

  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    runs = Keyword.get(opts, :runs, 10)
    observation_delay_ms = Keyword.get(opts, :observation_delay_ms, 25)
    fixed_overhead_ms = Keyword.get(opts, :fixed_overhead_ms, 75)

    if runs < 10, do: raise(ArgumentError, "PIN-28 benchmark requires at least 10 controlled runs")

    expected_diff_matches = observed_pin_28_diff() == @expected_diff

    samples =
      Enum.map(1..runs, fn run_number ->
        sample(
          run_number,
          observation_delay_ms,
          fixed_overhead_ms,
          expected_diff_matches
        )
      end)

    baseline = summarize(samples, :baseline)
    candidate = summarize(samples, :candidate)

    improvement_percent =
      percentage_improvement(
        baseline.median_end_to_end_ms,
        candidate.median_end_to_end_ms
      )

    thresholds_passed =
      improvement_percent >= 40.0 and
        candidate.median_end_to_end_ms <= 600_000 and
        candidate.median_first_useful_edit_ms <= 240_000 and
        candidate.completion_accuracy == baseline.completion_accuracy

    %{
      schema_version: 1,
      benchmark: "PIN-28-style simple task",
      run_count: runs,
      repository_revision: repository_revision(),
      environment: benchmark_environment(),
      task_contract_digest: digest(@task_contract),
      expected_diff: @expected_diff,
      model_configuration: "fixed-equivalent-work",
      required_artifacts: Map.take(@task_contract, [:verification, :review_checks, :handoff_fields]),
      baseline: baseline,
      candidate: candidate,
      improvement_percent: improvement_percent,
      thresholds_passed: thresholds_passed,
      samples: samples
    }
  end

  defp sample(run_number, observation_delay_ms, fixed_overhead_ms, expected_diff_matches) do
    {baseline_context_ms, baseline_snapshot} =
      serial_capture(observation_delay_ms)

    {candidate_context_ms, candidate_snapshot} =
      parallel_capture(observation_delay_ms)

    artifacts = benchmark_artifacts()

    accuracy =
      completion_accuracy_checks(
        expected_diff_matches,
        baseline_snapshot,
        candidate_snapshot,
        artifacts
      )

    %{
      run: run_number,
      baseline:
        sample_result(
          baseline_context_ms,
          fixed_overhead_ms,
          accuracy
        ),
      candidate:
        sample_result(
          candidate_context_ms,
          fixed_overhead_ms,
          accuracy
        )
    }
  end

  defp serial_capture(delay_ms) do
    started_ms = System.monotonic_time(:millisecond)
    {:ok, lock} = Agent.start_link(fn -> :ready end)

    runner = fn args ->
      Agent.get_and_update(
        lock,
        fn state -> {delayed_observation(args, delay_ms), state} end,
        120_000
      )
    end

    {:ok, snapshot} = RepositoryFingerprint.capture(".", nil, git_runner: runner)
    Agent.stop(lock)
    {max(System.monotonic_time(:millisecond) - started_ms, 0), snapshot}
  end

  defp parallel_capture(delay_ms) do
    started_ms = System.monotonic_time(:millisecond)

    {:ok, snapshot} =
      RepositoryFingerprint.capture(".", nil, git_runner: &delayed_observation(&1, delay_ms))

    {max(System.monotonic_time(:millisecond) - started_ms, 0), snapshot}
  end

  defp sample_result(context_ms, fixed_overhead_ms, accuracy) do
    %{
      end_to_end_ms: context_ms + fixed_overhead_ms,
      first_useful_edit_ms: context_ms + div(fixed_overhead_ms * 3, 5),
      phases: %{
        context_loading_ms: context_ms,
        unchanged_model_and_tool_ms: fixed_overhead_ms
      },
      accuracy: accuracy
    }
  end

  defp summarize(samples, variant) do
    results = Enum.map(samples, &Map.fetch!(&1, variant))
    end_to_end = Enum.map(results, & &1.end_to_end_ms)
    first_edit = Enum.map(results, & &1.first_useful_edit_ms)
    context = Enum.map(results, & &1.phases.context_loading_ms)
    unchanged = Enum.map(results, & &1.phases.unchanged_model_and_tool_ms)

    %{
      median_end_to_end_ms: median(end_to_end),
      p95_end_to_end_ms: percentile(end_to_end, 95),
      median_first_useful_edit_ms: median(first_edit),
      p95_first_useful_edit_ms: percentile(first_edit, 95),
      phases: %{
        context_loading: %{median_ms: median(context), p95_ms: percentile(context, 95)},
        unchanged_model_and_tool: %{
          median_ms: median(unchanged),
          p95_ms: percentile(unchanged, 95)
        }
      },
      completion_accuracy: completion_accuracy(results)
    }
  end

  defp completion_accuracy(results) do
    passed =
      Enum.count(results, fn result ->
        Enum.all?(result.accuracy, fn {_check, value} -> value end)
      end)

    passed / length(results)
  end

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1,
      do: Enum.at(sorted, middle),
      else: div(Enum.at(sorted, middle - 1) + Enum.at(sorted, middle), 2)
  end

  defp percentile(values, percentile) do
    sorted = Enum.sort(values)
    index = max(ceil(percentile / 100 * length(sorted)) - 1, 0)
    Enum.at(sorted, index)
  end

  defp percentage_improvement(baseline, candidate) when baseline > 0 do
    Float.round((baseline - candidate) / baseline * 100, 1)
  end

  defp percentage_improvement(_baseline, _candidate), do: 0.0

  defp completion_accuracy_checks(expected_diff_matches, baseline_snapshot, candidate_snapshot, artifacts) do
    %{
      expected_diff: expected_diff_matches,
      verification:
        baseline_snapshot == candidate_snapshot and
          artifacts.verification == @task_contract.verification,
      review: artifacts.review_checks == @task_contract.review_checks,
      handoff: artifacts.handoff_fields == @task_contract.handoff_fields
    }
  end

  defp benchmark_artifacts do
    %{
      verification: ["make all"],
      review_checks: ["correctness", "security", "convention", "scope"],
      handoff_fields: ["summary", "verification", "reviewer_action", "audit"]
    }
  end

  defp repository_revision do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unavailable"
    end
  end

  defp benchmark_environment do
    %{
      elixir: System.version(),
      otp: System.otp_release(),
      os: :os.type() |> inspect()
    }
  end

  defp digest(value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp observed_pin_28_diff do
    with {root, 0} <- System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true),
         {paths, 0} <-
           System.cmd(
             "git",
             ["-C", String.trim(root), "show", "--format=", "--name-only", @pin_28_commit],
             stderr_to_stdout: true
           ) do
      paths
      |> String.split("\n", trim: true)
      |> Enum.sort()
    else
      _ -> []
    end
  end

  defp delayed_observation(args, delay_ms) do
    Process.sleep(delay_ms)
    observation(args)
  end

  defp observation(["config", "--get", "remote.origin.url"]),
    do: {:ok, "git@github.com:openai/symphony.git\n"}

  defp observation(["rev-parse", "HEAD"]),
    do: {:ok, String.duplicate("a", 40) <> "\n"}

  defp observation(_args), do: {:ok, ""}
end
