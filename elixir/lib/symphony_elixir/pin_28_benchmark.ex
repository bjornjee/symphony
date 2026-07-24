defmodule SymphonyElixir.Pin28Benchmark do
  @moduledoc "Runs the controlled PIN-28 harness-overhead latency evaluation."

  alias SymphonyElixir.Linear.{Issue, TaskContract}
  alias SymphonyElixir.{RepositoryFingerprint, WorkflowProfile}

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
  @issue_description """
  ## Goal
  Add Makefile commands and setup documentation for running Symphony.

  ## Context
  PIN-28 is the controlled historical task.

  ## Scope
  In:
  - Makefile
  - docs/symphony-linear-setup.md

  Out:
  - Runtime behavior changes

  ## Acceptance Criteria
  - [ ] The expected Makefile and documentation diff is present.
  - [ ] Required verification, review, and handoff evidence passes.

  ## Verification
  Run the three commands recorded in the PIN-28 commit.

  ## Risk
  low

  ## Notes For Agent
  Workflow: chore
  """

  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    runs = Keyword.get(opts, :runs, 10)
    observation_delay_ms = Keyword.get(opts, :observation_delay_ms, 25)
    fixed_overhead_ms = Keyword.get(opts, :fixed_overhead_ms, 75)
    artifact_observer = Keyword.get(opts, :artifact_observer, &observed_pin_28_artifacts/0)

    if runs < 10, do: raise(ArgumentError, "PIN-28 benchmark requires at least 10 controlled runs")

    samples =
      Enum.map(1..runs, fn run_number ->
        sample(
          run_number,
          observation_delay_ms,
          fixed_overhead_ms,
          artifact_observer
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
        baseline.completion_accuracy == 1.0 and
        candidate.completion_accuracy == baseline.completion_accuracy

    %{
      schema_version: 1,
      benchmark: "PIN-28-style simple task",
      run_count: runs,
      repository_revision: repository_revision(),
      environment: benchmark_environment(),
      task_contract_digest: benchmark_task_contract_digest(),
      expected_diff: @expected_diff,
      model_configuration: %{
        kind: "deterministic-agent-replay",
        revision: 2,
        live_model: false
      },
      required_artifacts: Map.take(@task_contract, [:verification, :review_checks, :handoff_fields]),
      evidence: %{
        expected_diff: "PIN-28 commit 41808f55",
        verification: "deterministic lifecycle proof receipts",
        review: "deterministic lifecycle review",
        handoff: "validated lifecycle publication and handoff"
      },
      baseline: baseline,
      candidate: candidate,
      improvement_percent: improvement_percent,
      thresholds_passed: thresholds_passed,
      samples: samples
    }
  end

  defp sample(run_number, observation_delay_ms, fixed_overhead_ms, artifact_observer) do
    baseline =
      run_variant(
        &serial_capture/1,
        observation_delay_ms,
        fixed_overhead_ms,
        artifact_observer
      )

    candidate =
      run_variant(
        &parallel_capture/1,
        observation_delay_ms,
        fixed_overhead_ms,
        artifact_observer
      )

    baseline_accuracy =
      completion_accuracy_checks(
        baseline.snapshot,
        candidate.snapshot,
        baseline.lifecycle
      )

    candidate_accuracy =
      completion_accuracy_checks(
        baseline.snapshot,
        candidate.snapshot,
        candidate.lifecycle
      )

    %{
      run: run_number,
      baseline:
        baseline.result
        |> Map.put(:accuracy, baseline_accuracy)
        |> Map.put(:lifecycle, baseline.lifecycle),
      candidate:
        candidate.result
        |> Map.put(:accuracy, candidate_accuracy)
        |> Map.put(:lifecycle, candidate.lifecycle)
    }
  end

  defp run_variant(capture, observation_delay_ms, fixed_overhead_ms, artifact_observer) do
    started_ms = System.monotonic_time(:millisecond)
    snapshot = capture.(observation_delay_ms)
    context_completed_ms = System.monotonic_time(:millisecond)

    planning_started_ms = context_completed_ms
    pre_edit_ms = div(fixed_overhead_ms * 3, 5)
    Process.sleep(pre_edit_ms)
    planning = plan_lifecycle()
    planning_completed_ms = System.monotonic_time(:millisecond)

    implementation_started_ms = planning_completed_ms
    implementation = artifact_observer.()
    first_edit_ms = first_useful_edit_ms(implementation, started_ms)
    Process.sleep(fixed_overhead_ms - pre_edit_ms)
    implementation_completed_ms = System.monotonic_time(:millisecond)

    verification_started_ms = implementation_completed_ms
    verification = verify_lifecycle(implementation)
    verification_completed_ms = System.monotonic_time(:millisecond)

    review_started_ms = verification_completed_ms
    review = review_lifecycle(implementation)
    review_completed_ms = System.monotonic_time(:millisecond)

    publication_started_ms = review_completed_ms
    publication = publish_lifecycle(implementation, verification, review)
    publication_completed_ms = System.monotonic_time(:millisecond)

    handoff_started_ms = publication_completed_ms
    handoff = handoff_lifecycle(publication, verification)
    completed_ms = System.monotonic_time(:millisecond)

    %{
      snapshot: snapshot,
      lifecycle: %{
        planning: planning,
        implementation: implementation,
        verification: verification,
        review: review,
        publication: publication,
        handoff: handoff
      },
      result: %{
        end_to_end_ms: max(completed_ms - started_ms, 0),
        first_useful_edit_ms: first_edit_ms,
        phases: %{
          context_loading_ms: max(context_completed_ms - started_ms, 0),
          planning_ms: max(planning_completed_ms - planning_started_ms, 0),
          implementation_ms: max(implementation_completed_ms - implementation_started_ms, 0),
          verification_ms: max(verification_completed_ms - verification_started_ms, 0),
          review_ms: max(review_completed_ms - review_started_ms, 0),
          git_pr_ms: max(publication_completed_ms - publication_started_ms, 0),
          handoff_ms: max(completed_ms - handoff_started_ms, 0)
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

    phase_names =
      results
      |> hd()
      |> get_in([:phases])
      |> Map.keys()

    %{
      median_end_to_end_ms: median(end_to_end),
      p95_end_to_end_ms: percentile(end_to_end, 95),
      median_first_useful_edit_ms: median(first_edit),
      p95_first_useful_edit_ms: percentile(first_edit, 95),
      phases:
        Map.new(phase_names, fn phase ->
          values = Enum.map(results, &Map.fetch!(&1.phases, phase))
          {phase, %{median_ms: median(values), p95_ms: percentile(values, 95)}}
        end),
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

  defp completion_accuracy_checks(baseline_snapshot, candidate_snapshot, lifecycle) do
    %{
      expected_diff:
        lifecycle.planning.passed and
          lifecycle.implementation.changed_paths == @expected_diff,
      verification:
        baseline_snapshot == candidate_snapshot and
          Enum.all?(lifecycle.verification, & &1.passed),
      review:
        lifecycle.review
        |> Map.take(@task_contract.review_checks)
        |> Map.values()
        |> Enum.all?(),
      handoff:
        lifecycle.publication.passed and
          Enum.all?(@task_contract.handoff_fields, fn field ->
            lifecycle.handoff
            |> Map.get(field)
            |> non_empty_string?()
          end)
    }
  end

  defp plan_lifecycle do
    issue = %Issue{
      id: "pin-28-benchmark",
      identifier: "PIN-28",
      title: "chore: add Makefile commands for running Symphony",
      description: @issue_description,
      state: "In Progress",
      labels: ["codex-ready"]
    }

    with {:ok, contract} <- TaskContract.from_issue(issue),
         {:ok, profile} <- WorkflowProfile.select(contract) do
      %{passed: true, contract_digest: contract.digest, workflow: profile.name}
    else
      {:error, reason} -> %{passed: false, error: inspect(reason)}
    end
  end

  defp verify_lifecycle(implementation) do
    verification = observed_verification_commands(implementation.commit_message)

    Enum.map(@required_verification, fn command ->
      %{command: command, passed: MapSet.member?(verification, command)}
    end)
  end

  defp review_lifecycle(implementation) do
    subject = implementation.commit_message |> String.split("\n", parts: 2) |> List.first()

    %{
      "correctness" => implementation.changed_paths == @expected_diff,
      "security" => Enum.all?(implementation.changed_paths, &(Path.extname(&1) in ["", ".md"])),
      "convention" => String.starts_with?(subject, "chore: "),
      "scope" => implementation.changed_paths == @expected_diff
    }
  end

  defp publish_lifecycle(implementation, verification, review) do
    %{
      passed:
        implementation.commit_sha == @pin_28_commit and
          Enum.all?(verification, & &1.passed) and
          Enum.all?(review, fn {_name, passed} -> passed end),
      commit_sha: implementation.commit_sha
    }
  end

  defp handoff_lifecycle(publication, verification) do
    commands =
      verification
      |> Enum.filter(& &1.passed)
      |> Enum.map_join(", ", & &1.command)

    %{
      "summary" =>
        if(publication.passed,
          do: "Replayed the observed PIN-28 Makefile and documentation change.",
          else: ""
        ),
      "verification" => commands,
      "reviewer_action" => if(publication.passed, do: "Review the lifecycle report.", else: ""),
      "audit" => if(publication.passed, do: "Controlled deterministic lifecycle sample.", else: "")
    }
  end

  defp first_useful_edit_ms(%{changed_paths: [_path | _]}, started_ms),
    do: max(System.monotonic_time(:millisecond) - started_ms, 0)

  defp first_useful_edit_ms(_implementation, _started_ms), do: 600_001

  defp observed_pin_28_artifacts do
    diff = observed_pin_28_diff()
    commit_message = observed_pin_28_commit_message()

    %{
      changed_paths: diff,
      commit_message: commit_message,
      commit_sha: observed_pin_28_commit()
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

  defp benchmark_task_contract_digest do
    issue = %Issue{
      id: "pin-28-benchmark",
      identifier: "PIN-28",
      title: "chore: add Makefile commands for running Symphony",
      description: @issue_description
    }

    case TaskContract.from_issue(issue) do
      {:ok, contract} -> contract.digest
      {:error, _reason} -> digest(@task_contract)
    end
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

  defp observed_pin_28_commit do
    case System.cmd("git", ["cat-file", "-e", "#{@pin_28_commit}^{commit}"], stderr_to_stdout: true) do
      {_output, 0} -> @pin_28_commit
      _ -> nil
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
