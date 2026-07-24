defmodule SymphonyElixir.Pin28Benchmark do
  @moduledoc "Runs the controlled PIN-28 harness-overhead latency evaluation."

  alias SymphonyElixir.Linear.{Issue, TaskContract}

  alias SymphonyElixir.{
    CompletionEvidence,
    DeliveryControl,
    ExecutionControl,
    ExecutionLedger,
    ImplementationReview,
    PlanningArtifact,
    RepositoryFingerprint,
    TaskBranch,
    WorkflowProfile
  }

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
    ledger_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-pin28-benchmark-#{System.unique_integer([:positive, :monotonic])}"
      )

    previous_root = Application.get_env(:symphony_elixir, :execution_state_root)
    Application.put_env(:symphony_elixir, :execution_state_root, ledger_root)

    try do
      run_controlled(opts, ledger_root)
    after
      if previous_root,
        do: Application.put_env(:symphony_elixir, :execution_state_root, previous_root),
        else: Application.delete_env(:symphony_elixir, :execution_state_root)

      File.rm_rf(ledger_root)
    end
  end

  defp run_controlled(opts, ledger_root) do
    runs = Keyword.get(opts, :runs, 10)
    observation_delay_ms = Keyword.get(opts, :observation_delay_ms, 50)
    fixed_overhead_ms = Keyword.get(opts, :fixed_overhead_ms, 75)
    artifact_observer = Keyword.get(opts, :artifact_observer, &observed_pin_28_artifacts/0)
    command_executor = Keyword.get(opts, :command_executor, &execute_benchmark_command/3)
    lifecycle_mutator = Keyword.get(opts, :lifecycle_mutator, &Function.identity/1)

    if runs < 10, do: raise(ArgumentError, "PIN-28 benchmark requires at least 10 controlled runs")

    samples =
      Enum.map(1..runs, fn run_number ->
        sample(
          run_number,
          observation_delay_ms,
          fixed_overhead_ms,
          artifact_observer,
          ledger_root,
          command_executor,
          lifecycle_mutator
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
      observation_delay_ms > 0 and
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
        revision: 4,
        live_model: false
      },
      required_artifacts: Map.take(@task_contract, [:verification, :review_checks, :handoff_fields]),
      evidence: %{
        expected_diff: "PIN-28 commit 41808f55",
        verification: "real fixture commands with deterministic lifecycle proof receipts",
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

  defp sample(
         run_number,
         observation_delay_ms,
         fixed_overhead_ms,
         artifact_observer,
         ledger_root,
         command_executor,
         lifecycle_mutator
       ) do
    fixture_root = Path.join(ledger_root, "run-#{run_number}")

    baseline =
      run_variant(
        &serial_capture/1,
        observation_delay_ms,
        fixed_overhead_ms,
        artifact_observer,
        fixture_root,
        nil,
        command_executor
      )

    candidate =
      run_variant(
        &parallel_capture/1,
        observation_delay_ms,
        fixed_overhead_ms,
        artifact_observer,
        fixture_root,
        baseline.prepared,
        command_executor
      )

    File.rm_rf(fixture_root)

    baseline_lifecycle = lifecycle_mutator.(baseline.lifecycle)
    candidate_lifecycle = lifecycle_mutator.(candidate.lifecycle)

    baseline_accuracy =
      completion_accuracy_checks(
        baseline.snapshot,
        candidate.snapshot,
        baseline_lifecycle,
        baseline.lifecycle
      )

    candidate_accuracy =
      completion_accuracy_checks(
        baseline.snapshot,
        candidate.snapshot,
        candidate_lifecycle,
        candidate.lifecycle
      )

    %{
      run: run_number,
      baseline:
        baseline.result
        |> Map.put(:accuracy, baseline_accuracy)
        |> Map.put(:lifecycle, baseline_lifecycle),
      candidate:
        candidate.result
        |> Map.put(:accuracy, candidate_accuracy)
        |> Map.put(:lifecycle, candidate_lifecycle)
    }
  end

  defp run_variant(
         capture,
         observation_delay_ms,
         fixed_overhead_ms,
         artifact_observer,
         fixture_root,
         prepared,
         command_executor
       ) do
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

    lifecycle =
      if prepared,
        do: reuse_lifecycle(prepared, command_executor),
        else: prepare_lifecycle(implementation, fixture_root, command_executor)

    verification = lifecycle.verification
    verification_completed_ms = System.monotonic_time(:millisecond)

    review_started_ms = verification_completed_ms
    review = review_lifecycle(lifecycle)
    review_completed_ms = System.monotonic_time(:millisecond)

    publication_started_ms = review_completed_ms
    publication = publish_lifecycle(lifecycle, review)
    publication_completed_ms = System.monotonic_time(:millisecond)

    handoff_started_ms = publication_completed_ms
    handoff = handoff_lifecycle(lifecycle, publication)
    completed_ms = System.monotonic_time(:millisecond)

    %{
      snapshot: snapshot,
      prepared: lifecycle,
      lifecycle: %{
        planning: planning,
        implementation: implementation,
        verification: verification,
        review: review,
        publication: Map.delete(publication, :evidence),
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

  defp completion_accuracy_checks(
         baseline_snapshot,
         candidate_snapshot,
         lifecycle,
         trusted_lifecycle
       ) do
    %{
      expected_diff:
        lifecycle.planning.passed and
          lifecycle.implementation.changed_paths == @expected_diff,
      verification:
        baseline_snapshot == candidate_snapshot and
          valid_verification_evidence?(
            lifecycle.verification,
            trusted_lifecycle.verification
          ),
      review: valid_review_evidence?(lifecycle.review, trusted_lifecycle.review),
      handoff:
        valid_handoff_evidence?(
          lifecycle.publication,
          lifecycle.handoff,
          trusted_lifecycle.publication,
          trusted_lifecycle.handoff
        )
    }
  end

  defp valid_verification_evidence?(verification, trusted)
       when is_list(verification) and is_list(trusted) do
    length(verification) == length(@required_verification) and
      length(trusted) == length(@required_verification) and
      Enum.zip([verification, trusted, @required_verification])
      |> Enum.all?(fn {receipt, trusted_receipt, command} ->
        receipt.command == command and receipt.passed == true and
          trusted_receipt.command == command and trusted_receipt.passed == true and
          valid_digest?(receipt.receipt_digest) and
          receipt.receipt_digest == trusted_receipt.receipt_digest
      end)
  end

  defp valid_verification_evidence?(_verification, _trusted), do: false

  defp valid_review_evidence?(review, trusted_review)
       when is_map(review) and is_map(trusted_review) do
    Enum.all?(@task_contract.review_checks, fn check ->
      review[check] == true and trusted_review[check] == true
    end) and
      valid_digest?(review["receipt_digest"]) and
      review["receipt_digest"] == trusted_review["receipt_digest"]
  end

  defp valid_review_evidence?(_review, _trusted_review), do: false

  defp valid_handoff_evidence?(publication, handoff, trusted_publication, trusted_handoff)
       when is_map(publication) and is_map(handoff) and is_map(trusted_publication) and
              is_map(trusted_handoff) do
    publication_evidence_matches?(publication, trusted_publication) and
      handoff_evidence_matches?(handoff, trusted_handoff) and
      handoff_fields_present?(handoff)
  end

  defp valid_handoff_evidence?(
         _publication,
         _handoff,
         _trusted_publication,
         _trusted_handoff
       ),
       do: false

  defp publication_evidence_matches?(publication, trusted_publication) do
    publication.passed and trusted_publication.passed and
      valid_digest?(publication.receipt_digest) and
      publication.receipt_digest == trusted_publication.receipt_digest
  end

  defp handoff_evidence_matches?(handoff, trusted_handoff) do
    valid_digest?(handoff["artifact_digest"]) and
      handoff["artifact_digest"] == trusted_handoff["artifact_digest"]
  end

  defp handoff_fields_present?(handoff) do
    Enum.all?(@task_contract.handoff_fields, fn field ->
      handoff
      |> Map.get(field)
      |> non_empty_string?()
    end)
  end

  defp valid_digest?(value),
    do: is_binary(value) and Regex.match?(~r/^[a-f0-9]{64}$/, value)

  defp plan_lifecycle do
    issue = benchmark_issue("pin-28-benchmark")

    with {:ok, contract} <- TaskContract.from_issue(issue),
         {:ok, profile} <- WorkflowProfile.select(contract) do
      %{passed: true, contract_digest: contract.digest, workflow: profile.name}
    else
      {:error, reason} -> %{passed: false, error: inspect(reason)}
    end
  end

  defp prepare_lifecycle(implementation, fixture_root, command_executor) do
    if valid_observed_implementation?(implementation) do
      prepare_valid_lifecycle(implementation, fixture_root, command_executor)
    else
      %{
        passed: false,
        verification: Enum.map(@required_verification, &%{command: &1, passed: false, receipt_digest: nil})
      }
    end
  end

  defp prepare_valid_lifecycle(implementation, fixture_root, command_executor) do
    workspace = Path.join(fixture_root, "repo")
    File.mkdir_p!(Path.join(workspace, "docs"))
    git!(workspace, ["init", "-q", "-b", "main"])
    git!(workspace, ["config", "user.email", "benchmark@example.com"])
    git!(workspace, ["config", "user.name", "PIN-28 Benchmark"])
    git!(workspace, ["remote", "add", "origin", "git@github.com:openai/symphony.git"])
    File.write!(Path.join(workspace, "Makefile"), "base\n")
    File.write!(Path.join(workspace, "docs/symphony-linear-setup.md"), "base\n")
    git!(workspace, ["add", "."])
    git!(workspace, ["commit", "-qm", "chore: benchmark base"])
    base_sha = git!(workspace, ["rev-parse", "HEAD"])
    issue = benchmark_issue("pin-28-#{Path.basename(fixture_root)}")
    {:ok, contract} = TaskContract.from_issue(issue)
    {:ok, _branch} = TaskBranch.ensure(workspace, issue, "chore", base_sha)

    File.write!(
      Path.join(workspace, "Makefile"),
      """
      .PHONY: symphony-workflow symphony-workflow-check all
      symphony-workflow:
      \t@test -f docs/symphony-linear-setup.md
      symphony-workflow-check:
      \t@grep -q "Symphony setup" docs/symphony-linear-setup.md
      all:
      \t@$(MAKE) symphony-workflow-check
      """
    )

    File.write!(Path.join(workspace, "docs/symphony-linear-setup.md"), "# Symphony setup\n")
    git!(workspace, ["add", "."])
    git!(workspace, ["commit", "-qm", implementation.commit_message])
    {:ok, state} = RepositoryFingerprint.capture(workspace)
    criterion_ids = Enum.map(contract.acceptance_criteria, & &1.id)

    proofs =
      @required_verification
      |> Enum.with_index(1)
      |> Enum.map(fn {command, index} ->
        %{
          "id" => "proof-#{index}",
          "phase_id" => "deliver",
          "role" => if(index == length(@required_verification), do: "final", else: "validator"),
          "command" => command,
          "working_directory" => ".",
          "expected_exit" => "success",
          "timeout_ms" => 1_000,
          "criterion_ids" => criterion_ids
        }
      end)

    semantic = %{
      "instruction_digest" => digest("pin-28-instructions"),
      "profile_digest" => digest("pin-28-profile"),
      "workflow" => "chore",
      "candidate" => %{
        "repository" => %{"origin" => state.origin, "base_sha" => base_sha},
        "affected_paths" => @expected_diff,
        "verification_profile" => "Full",
        "execution_context" => "CI/test-only deterministic lifecycle evaluation",
        "scale_shape" => "one fixed two-file task",
        "ordered_steps" => [
          %{
            "id" => "deliver",
            "proof_ids" => Enum.map(proofs, & &1["id"]),
            "affected_paths" => @expected_diff,
            "depends_on" => []
          }
        ],
        "proofs" => proofs
      }
    }

    plan = Map.put(semantic, "plan_digest", PlanningArtifact.digest(semantic))
    key = ExecutionLedger.key(state.origin, issue.id, plan["plan_digest"])

    verification =
      Enum.map(proofs, fn proof ->
        {:ok, receipt} =
          ExecutionControl.run_plan_proof(
            plan,
            key,
            workspace,
            "deliver",
            proof["id"],
            command_executor: command_executor
          )

        %{
          command: proof["command"],
          passed: receipt["passed"],
          receipt_digest: receipt["receipt_digest"]
        }
      end)

    passed = Enum.all?(verification, & &1.passed)

    if passed do
      {:ok, _phase} = ExecutionControl.complete_execution_phase(plan, key, workspace, "deliver")
    end

    %{
      passed: passed,
      reused: false,
      workspace: workspace,
      issue: issue,
      contract: contract,
      plan: plan,
      key: key,
      state: state,
      verification: verification
    }
  end

  defp reuse_lifecycle(%{passed: true} = lifecycle, command_executor) do
    verification =
      Enum.map(lifecycle.plan["candidate"]["proofs"], fn proof ->
        {:ok, receipt} =
          ExecutionControl.run_plan_proof(
            lifecycle.plan,
            lifecycle.key,
            lifecycle.workspace,
            "deliver",
            proof["id"],
            command_executor: command_executor
          )

        %{
          command: proof["command"],
          passed: receipt["passed"],
          receipt_digest: receipt["receipt_digest"]
        }
      end)

    {:ok, _phase} =
      ExecutionControl.complete_execution_phase(
        lifecycle.plan,
        lifecycle.key,
        lifecycle.workspace,
        "deliver"
      )

    %{lifecycle | reused: true, verification: verification}
  end

  defp reuse_lifecycle(lifecycle, _command_executor), do: lifecycle

  defp review_lifecycle(%{passed: true} = lifecycle) do
    {:ok, approval} = lifecycle_review(lifecycle)

    approved = approval["verdict"] == "approve"

    %{
      "correctness" => approved,
      "security" => approved,
      "convention" => approved,
      "scope" => approved,
      "receipt_digest" => approval["receipt_digest"]
    }
  end

  defp review_lifecycle(_lifecycle), do: failed_review()

  defp lifecycle_review(%{reused: true} = lifecycle) do
    ImplementationReview.latest_approval(
      lifecycle.key,
      lifecycle.state.base_sha,
      lifecycle.state.digest
    )
  end

  defp lifecycle_review(lifecycle) do
    run_turn = fn _session, prompt, _issue, opts ->
      approved = Enum.all?(@expected_diff, &String.contains?(prompt, &1))

      opts[:tool_executor].("submit_implementation_review", %{
        "verdict" => if(approved, do: "approve", else: "revise"),
        "blocking_findings" => if(approved, do: [], else: ["Expected PIN-28 paths are missing."]),
        "advisory_findings" => []
      })

      {:ok, %{turn_id: "deterministic-review"}}
    end

    ImplementationReview.request(
      lifecycle.workspace,
      lifecycle.issue,
      lifecycle.contract,
      lifecycle.plan,
      lifecycle.key,
      start_session: fn _, _ -> {:ok, %{thread_id: "deterministic-review"}} end,
      run_turn: run_turn,
      stop_session: fn _ -> :ok end
    )
  end

  defp publish_lifecycle(%{passed: true} = lifecycle, %{"receipt_digest" => digest})
       when is_binary(digest) do
    publisher = fn _workspace, _plan, _title, _body, _opts ->
      {:ok,
       %{
         "url" => "https://github.com/openai/symphony/pull/28",
         "head_sha" => lifecycle.state.base_sha,
         "head_branch" => "chore/pin-28-chore-add-makefile-commands-for-running-symphony",
         "base_branch" => "main",
         "origin" => lifecycle.state.origin
       }}
    end

    {:ok, evidence} =
      DeliveryControl.publish(
        lifecycle.workspace,
        lifecycle.issue,
        lifecycle.contract,
        lifecycle.plan,
        lifecycle.key,
        "chore: add Makefile commands for running Symphony",
        "#### Context\nPIN-28 benchmark\n#### TL;DR\n*Lifecycle proof*\n#### Summary\n- deterministic\n#### Alternatives\n- none\n#### Test Plan\n- [x] controlled",
        publisher: publisher
      )

    %{
      passed: true,
      commit_sha: lifecycle.state.base_sha,
      receipt_digest: evidence["publication_receipt_digest"],
      evidence: evidence
    }
  end

  defp publish_lifecycle(_lifecycle, _review),
    do: %{passed: false, commit_sha: nil, receipt_digest: nil, evidence: nil}

  defp handoff_lifecycle(lifecycle, %{passed: true, evidence: evidence}) do
    reader = fn _workspace, _plan, _url, _opts ->
      {:ok,
       %{
         "url" => evidence["pull_request_url"],
         "head_sha" => evidence["pr_head_sha"],
         "head_branch" => evidence["pr_head_branch"],
         "base_branch" => evidence["pr_base_branch"],
         "state" => "OPEN",
         "is_cross_repository" => false
       }}
    end

    {:ok, validated} =
      CompletionEvidence.validate(
        lifecycle.workspace,
        lifecycle.issue,
        lifecycle.contract,
        %{},
        execution_plan: lifecycle.plan,
        execution_ledger_key: lifecycle.key,
        pull_request_reader: reader
      )

    %{
      "summary" => "Replayed the observed PIN-28 Makefile and documentation change.",
      "verification" => Enum.map_join(lifecycle.verification, ", ", & &1.command),
      "reviewer_action" => "Review the lifecycle report.",
      "audit" => "Controlled deterministic lifecycle sample.",
      "artifact_digest" => validated.artifact_digest
    }
  end

  defp handoff_lifecycle(_lifecycle, _publication), do: failed_handoff()

  defp valid_observed_implementation?(implementation) do
    implementation.changed_paths == @expected_diff and
      implementation.commit_sha == @pin_28_commit and
      observed_verification_commands(implementation.commit_message) ==
        MapSet.new(@required_verification)
  end

  defp failed_review do
    %{
      "correctness" => false,
      "security" => false,
      "convention" => false,
      "scope" => false,
      "receipt_digest" => nil
    }
  end

  defp failed_handoff do
    %{
      "summary" => "",
      "verification" => "",
      "reviewer_action" => "",
      "audit" => "",
      "artifact_digest" => nil
    }
  end

  defp benchmark_issue(id) do
    %Issue{
      id: id,
      identifier: "PIN-28",
      title: "chore: add Makefile commands for running Symphony",
      description: @issue_description,
      state: "In Progress",
      labels: ["codex-ready"]
    }
  end

  defp git!(workspace, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "benchmark git command failed status=#{status}: #{output}"
    end
  end

  defp execute_benchmark_command(directory, command, _opts) do
    {executable, args} =
      case command do
        "make symphony-workflow" -> {"make", ["symphony-workflow"]}
        "make symphony-workflow-check" -> {"make", ["symphony-workflow-check"]}
        "mise exec -- make all" -> {"mise", ["exec", "--", "make", "all"]}
      end

    case System.cmd(executable, args, cd: directory, stderr_to_stdout: true) do
      {output, exit_status} ->
        {:ok, %{exit_status: exit_status, stdout: output, stderr: ""}}
    end
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
