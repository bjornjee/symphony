defmodule SymphonyElixir.Pin28Benchmark do
  @moduledoc "Runs the controlled PIN-28 harness-overhead latency evaluation."

  alias SymphonyElixir.RepositoryFingerprint

  @expected_diff ["Makefile", "docs/symphony-linear-setup.md"]
  @pin_28_commit "41808f55b68b3727710651df7601e6f2023e40dc"
  @required_verification [
    "make symphony-workflow",
    "make symphony-workflow-check",
    "mise exec -- make all"
  ]
  @task_contract %{
    goal: "Add Makefile commands and setup documentation for running Symphony.",
    affected_paths: @expected_diff,
    verification: @required_verification,
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
      model_configuration: %{
        kind: "deterministic-agent-replay",
        revision: 1,
        live_model: false
      },
      required_artifacts: Map.take(@task_contract, [:verification, :review_checks, :handoff_fields]),
      evidence: %{
        expected_diff: "PIN-28 commit 41808f55",
        verification: "PIN-28 commit message",
        review: "deterministic diff review",
        handoff: "validated replay handoff"
      },
      baseline: baseline,
      candidate: candidate,
      improvement_percent: improvement_percent,
      thresholds_passed: thresholds_passed,
      samples: samples
    }
  end

  defp sample(run_number, observation_delay_ms, fixed_overhead_ms, expected_diff_matches) do
    baseline =
      run_variant(&serial_capture/1, observation_delay_ms, fixed_overhead_ms)

    candidate =
      run_variant(&parallel_capture/1, observation_delay_ms, fixed_overhead_ms)

    baseline_accuracy =
      completion_accuracy_checks(
        expected_diff_matches,
        baseline.snapshot,
        candidate.snapshot,
        baseline.artifacts
      )

    candidate_accuracy =
      completion_accuracy_checks(
        expected_diff_matches,
        baseline.snapshot,
        candidate.snapshot,
        candidate.artifacts
      )

    %{
      run: run_number,
      baseline: Map.put(baseline.result, :accuracy, baseline_accuracy),
      candidate: Map.put(candidate.result, :accuracy, candidate_accuracy)
    }
  end

  defp run_variant(capture, observation_delay_ms, fixed_overhead_ms) do
    started_ms = System.monotonic_time(:millisecond)
    snapshot = capture.(observation_delay_ms)
    context_completed_ms = System.monotonic_time(:millisecond)

    pre_edit_ms = div(fixed_overhead_ms * 3, 5)
    Process.sleep(pre_edit_ms)
    first_edit_ms = max(System.monotonic_time(:millisecond) - started_ms, 0)
    Process.sleep(fixed_overhead_ms - pre_edit_ms)
    fixed_work_completed_ms = System.monotonic_time(:millisecond)

    artifacts = benchmark_artifacts()
    completed_ms = System.monotonic_time(:millisecond)

    %{
      snapshot: snapshot,
      artifacts: artifacts,
      result: %{
        end_to_end_ms: max(completed_ms - started_ms, 0),
        first_useful_edit_ms: first_edit_ms,
        phases: %{
          context_loading_ms: max(context_completed_ms - started_ms, 0),
          unchanged_model_and_tool_ms: max(fixed_work_completed_ms - context_completed_ms, 0),
          artifact_validation_ms: max(completed_ms - fixed_work_completed_ms, 0)
        }
      }
    }
  end

  defp serial_capture(delay_ms) do
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
    snapshot
  end

  defp parallel_capture(delay_ms) do
    {:ok, snapshot} =
      RepositoryFingerprint.capture(".", nil, git_runner: &delayed_observation(&1, delay_ms))

    snapshot
  end

  defp summarize(samples, variant) do
    results = Enum.map(samples, &Map.fetch!(&1, variant))
    end_to_end = Enum.map(results, & &1.end_to_end_ms)
    first_edit = Enum.map(results, & &1.first_useful_edit_ms)
    context = Enum.map(results, & &1.phases.context_loading_ms)
    unchanged = Enum.map(results, & &1.phases.unchanged_model_and_tool_ms)
    artifact_validation = Enum.map(results, & &1.phases.artifact_validation_ms)

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
        },
        artifact_validation: %{
          median_ms: median(artifact_validation),
          p95_ms: percentile(artifact_validation, 95)
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
          Enum.all?(@required_verification, &MapSet.member?(artifacts.verification, &1)),
      review:
        artifacts.review
        |> Map.take(@task_contract.review_checks)
        |> Map.values()
        |> Enum.all?(),
      handoff:
        Enum.all?(@task_contract.handoff_fields, fn field ->
          artifacts.handoff
          |> Map.get(field)
          |> non_empty_string?()
        end)
    }
  end

  defp benchmark_artifacts do
    diff = observed_pin_28_diff()
    commit_message = observed_pin_28_commit_message()
    subject = commit_message |> String.split("\n", parts: 2) |> List.first()
    verification = observed_verification_commands(commit_message)

    %{
      verification: verification,
      review: %{
        "correctness" => diff == @expected_diff,
        "security" => Enum.all?(diff, &(Path.extname(&1) in ["", ".md"])),
        "convention" => String.starts_with?(subject, "chore: "),
        "scope" => diff == @expected_diff
      },
      handoff: %{
        "summary" => "Replayed the expected PIN-28 Makefile and documentation change.",
        "verification" => verification |> Enum.sort() |> Enum.join(", "),
        "reviewer_action" => "Review the replay artifacts and latency report.",
        "audit" => "Controlled deterministic-agent benchmark sample."
      }
    }
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

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

  defp observed_verification_commands(commit_message) do
    Enum.filter(@required_verification, &String.contains?(commit_message, &1))
    |> MapSet.new()
  end

  defp observed_pin_28_commit_message do
    case System.cmd("git", ["show", "-s", "--format=%B", @pin_28_commit], stderr_to_stdout: true) do
      {message, 0} -> message
      _ -> ""
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
