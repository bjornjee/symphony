defmodule SymphonyElixir.CompletionEvidenceTest do
  use ExUnit.Case

  import SymphonyElixir.TaskContractFixtures
  alias SymphonyElixir.CompletionEvidence
  alias SymphonyElixir.Linear.TaskContract

  @origin_url "git@github.com:bjornjee/symphony.git"
  @pr_url "https://github.com/bjornjee/symphony/pull/42"
  @head_sha String.duplicate("a", 40)
  @execution_plan_digest String.duplicate("e", 64)
  @profile_digest String.duplicate("f", 64)

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-completion-evidence-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    task = issue()
    {:ok, contract} = TaskContract.from_issue(task)

    %{workspace: workspace, task: task, contract: contract}
  end

  test "accepts exact criterion coverage backed by engine-observed successful commands", context do
    observed = observed_proofs(context.contract)
    write_evidence(context, valid_evidence(context, observed))

    assert {:ok,
            %{
              pull_request_url: @pr_url,
              artifact_digest: artifact_digest,
              criteria: criteria
            }} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )

    assert artifact_digest =~ ~r/^[a-f0-9]{64}$/

    assert Enum.map(criteria, & &1.criterion_id) ==
             Enum.map(context.contract.acceptance_criteria, & &1.id)

    assert Enum.all?(criteria, &String.starts_with?(&1.proof_event_id, "proof-"))
  end

  test "keeps semantic artifact identity stable when a retry regenerates proof event ids", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    write_evidence(context, evidence)

    assert {:ok, %{artifact_digest: first_digest}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )

    retried_criteria =
      evidence["criteria"]
      |> Enum.with_index(1)
      |> Enum.map(fn {criterion, index} ->
        put_in(criterion, ["proof", "event_id"], "retry-proof-#{index}")
      end)

    retried_observed =
      Map.new(1..length(retried_criteria), fn index ->
        {"retry-proof-#{index}", %{exit_code: 0, sequence: index, head_sha: @head_sha}}
      end)

    write_evidence(context, %{
      evidence
      | "criteria" => retried_criteria,
        "workflow_proof" => %{"final_proof_event_id" => "retry-proof-1"}
    })

    assert {:ok, %{artifact_digest: ^first_digest}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               retried_observed,
               validation_opts()
             )
  end

  test "rejects a missing completion evidence artifact", context do
    assert {:error, :completion_evidence_missing} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               %{},
               validation_opts()
             )
  end

  test "rejects an oversized engine proof ledger before reading workspace evidence", context do
    observed = Map.new(1..257, &{"proof-#{&1}", %{exit_code: 0}})

    assert {:error, {:observed_proof_limit_exceeded, 256}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )
  end

  test "rejects malformed completion evidence", context do
    File.mkdir_p!(Path.dirname(CompletionEvidence.path(context.workspace)))
    File.write!(CompletionEvidence.path(context.workspace), "not-json")

    assert {:error, {:malformed_completion_evidence, _reason}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               %{},
               validation_opts()
             )
  end

  test "rejects a non-object completion envelope", context do
    File.mkdir_p!(Path.dirname(CompletionEvidence.path(context.workspace)))
    File.write!(CompletionEvidence.path(context.workspace), "[]")

    assert {:error, {:malformed_completion_evidence, :not_an_object}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               %{},
               validation_opts()
             )
  end

  test "rejects an oversized local completion envelope", context do
    File.mkdir_p!(Path.dirname(CompletionEvidence.path(context.workspace)))
    File.write!(CompletionEvidence.path(context.workspace), String.duplicate("x", 131_073))

    assert {:error, {:completion_evidence_too_large, 131_072}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               %{},
               validation_opts()
             )
  end

  test "rejects a symlinked completion envelope", context do
    target = Path.join(context.workspace, "agent-evidence.json")
    File.write!(target, "{}")
    File.mkdir_p!(Path.dirname(CompletionEvidence.path(context.workspace)))
    File.ln_s!(target, CompletionEvidence.path(context.workspace))

    assert {:error, {:completion_evidence_read_failed, {:invalid_artifact_type, :symlink}}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               %{},
               validation_opts()
             )
  end

  test "rejects evidence for a stale plan digest", context do
    observed = observed_proofs(context.contract)
    write_evidence(context, %{valid_evidence(context, observed) | "plan_digest" => String.duplicate("0", 64)})

    assert {:error, {:completion_evidence_plan_digest_mismatch, _, _}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )
  end

  test "rejects unsupported schema and malformed criterion entries", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    write_evidence(context, %{evidence | "schema_version" => 3})

    assert {:error, {:unsupported_completion_evidence_version, 3}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )

    write_evidence(context, %{evidence | "criteria" => [%{} | tl(evidence["criteria"])]})

    assert {:error, :malformed_criterion_evidence} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )
  end

  test "rejects evidence for another issue identity", context do
    expected_issue_id = context.task.id
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    write_evidence(context, %{evidence | "issue_id" => "other-issue"})

    assert {:error, {:completion_evidence_issue_mismatch, "other-issue", ^expected_issue_id}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )
  end

  test "rejects evidence for another issue identifier", context do
    expected_identifier = context.task.identifier
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    write_evidence(context, %{evidence | "issue_identifier" => "OTHER-1"})

    assert {:error, {:completion_evidence_identifier_mismatch, "OTHER-1", ^expected_identifier}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )
  end

  test "rejects missing criterion evidence", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    write_evidence(context, %{evidence | "criteria" => Enum.drop(evidence["criteria"], 1)})

    [missing | _] = context.contract.acceptance_criteria
    missing_id = missing.id

    assert {:error, {:missing_criterion_evidence, [^missing_id]}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )
  end

  test "rejects unmatched criterion evidence", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)

    unmatched = %{
      "criterion_id" => "ac-#{String.duplicate("f", 64)}",
      "proof" => %{"kind" => "run_audit_command", "event_id" => "proof-extra"}
    }

    write_evidence(context, %{evidence | "criteria" => evidence["criteria"] ++ [unmatched]})

    assert {:error, {:unmatched_criterion_evidence, [_id]}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               Map.put(observed, "proof-extra", %{exit_code: 0, sequence: 99, head_sha: @head_sha}),
               validation_opts()
             )
  end

  test "rejects duplicate criterion evidence", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    [first | _] = evidence["criteria"]
    write_evidence(context, %{evidence | "criteria" => evidence["criteria"] ++ [first]})

    assert {:error, {:duplicate_criterion_evidence, [first_id]}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )

    assert first_id == first["criterion_id"]
  end

  test "rejects agent-asserted proof absent from the engine ledger", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    [first | rest] = evidence["criteria"]

    forged = put_in(first, ["proof", "event_id"], "agent-asserted-success")
    write_evidence(context, %{evidence | "criteria" => [forged | rest]})

    assert {:error, {:unobserved_criterion_proof, criterion_id, "agent-asserted-success"}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )

    assert criterion_id == first["criterion_id"]
  end

  test "rejects malformed criterion proof", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    [first | rest] = evidence["criteria"]
    write_evidence(context, %{evidence | "criteria" => [Map.delete(first, "proof") | rest]})

    assert {:error, {:malformed_criterion_proof, criterion_id}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )

    assert criterion_id == first["criterion_id"]
  end

  test "rejects failed and malformed engine observations", context do
    evidence = valid_evidence(context, observed_proofs(context.contract))
    [first, second] = evidence["criteria"]
    first_event = get_in(first, ["proof", "event_id"])
    second_event = get_in(second, ["proof", "event_id"])
    write_evidence(context, evidence)

    assert {:error, {:failed_criterion_proof, _, ^first_event, 1}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               %{first_event => %{exit_code: 1}, second_event => %{exit_code: 0}},
               validation_opts()
             )

    assert {:error, {:malformed_observed_proof, ^first_event}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               %{first_event => :invalid, second_event => %{exit_code: 0}},
               validation_opts()
             )
  end

  test "reads and normalizes the workspace git origin", context do
    System.cmd("git", ["-C", context.workspace, "init", "-b", "main"])

    System.cmd("git", [
      "-C",
      context.workspace,
      "remote",
      "add",
      "origin",
      "https://github.com/bjornjee/symphony.git"
    ])

    observed = observed_proofs(context.contract)
    write_evidence(context, valid_evidence(context, observed))
    opts = Keyword.delete(validation_opts(), :origin_url)

    assert {:ok, %{pull_request_url: @pr_url}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               opts
             )
  end

  test "rejects an unavailable workspace git origin", context do
    observed = observed_proofs(context.contract)
    write_evidence(context, valid_evidence(context, observed))
    opts = Keyword.delete(validation_opts(), :origin_url)

    assert {:error, {:repository_origin_unavailable, {_status, _output}}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               opts
             )
  end

  test "validates and rejects completion evidence through the SSH boundary", context do
    original_path = System.get_env("PATH")
    original_gh_failure = System.get_env("FAKE_GH_FAIL")
    original_origin_failure = System.get_env("FAKE_ORIGIN_FAIL")
    fake_bin = Path.join(context.workspace, "fake-bin")
    fake_ssh = Path.join(fake_bin, "ssh")
    fake_gh = Path.join(fake_bin, "gh")
    File.mkdir_p!(fake_bin)

    File.write!(fake_ssh, """
    #!/bin/sh
    for arg in "$@"; do remote_command="$arg"; done
    case "$remote_command" in
      *"gh pr view"*)
        if [ "${FAKE_GH_FAIL:-}" = "1" ]; then echo failed; exit 7; fi
        echo '{"url":"#{@pr_url}","headRefOid":"#{@head_sha}"}'
        ;;
      *"remote get-url origin"*)
        if [ "${FAKE_ORIGIN_FAIL:-}" = "1" ]; then echo missing; exit 2; fi
        echo "#{@origin_url}"
        ;;
      *) eval "$remote_command" ;;
    esac
    """)

    File.write!(fake_gh, """
    #!/bin/sh
    if [ "${FAKE_GH_FAIL:-}" = "1" ]; then
      echo failed
      exit 7
    fi
    for arg in "$@"; do
      case "$arg" in
        https://github.com/*/pull/*) printf '%s\n' "$arg"; exit 0 ;;
      esac
    done
    exit 8
    """)

    File.chmod!(fake_ssh, 0o755)
    File.chmod!(fake_gh, 0o755)
    System.put_env("PATH", fake_bin <> ":" <> (original_path || ""))

    on_exit(fn ->
      restore_env("PATH", original_path)
      restore_env("FAKE_GH_FAIL", original_gh_failure)
      restore_env("FAKE_ORIGIN_FAIL", original_origin_failure)
    end)

    System.cmd("git", ["-C", context.workspace, "init", "-b", "main"])
    System.cmd("git", ["-C", context.workspace, "remote", "add", "origin", @origin_url])

    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    write_evidence(context, evidence)

    opts = [
      worker_host: "worker-a",
      execution_plan: execution_plan(),
      repository_head_sha: @head_sha
    ]

    assert {:ok, %{pull_request_url: @pr_url}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               opts
             )

    System.put_env("FAKE_GH_FAIL", "1")

    assert {:error, {:pull_request_unavailable, {"worker-a", 7, "failed"}}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               opts
             )

    System.delete_env("FAKE_GH_FAIL")
    File.rm!(CompletionEvidence.path(context.workspace))

    assert {:error, :completion_evidence_missing} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               opts
             )

    File.write!(CompletionEvidence.path(context.workspace), String.duplicate("x", 131_073))

    assert {:error, {:completion_evidence_too_large, 131_072}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               opts
             )

    write_evidence(context, evidence)
    System.put_env("FAKE_ORIGIN_FAIL", "1")

    assert {:error, {:repository_origin_unavailable, {"worker-a", 2, _output}}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               opts
             )
  end

  test "rejects mismatched and malformed PR verifier results", context do
    observed = observed_proofs(context.contract)
    write_evidence(context, valid_evidence(context, observed))

    mismatch_opts =
      Keyword.put(validation_opts(), :pull_request_verifier, fn _, _, _ ->
        {:ok, %{url: "https://github.com/bjornjee/symphony/pull/43", head_sha: @head_sha}}
      end)

    assert {:error, {:pull_request_url_mismatch, _details}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               mismatch_opts
             )

    malformed_opts =
      Keyword.put(validation_opts(), :pull_request_verifier, fn _, _, _ -> :unexpected end)

    assert {:error, {:pull_request_verification_failed, :unexpected}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               malformed_opts
             )
  end

  test "rejects malformed PR numbers and unsupported repository origins", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    write_evidence(context, %{evidence | "pull_request_url" => "https://github.com/bjornjee/symphony/pull/not-a-number"})

    assert {:error, {:invalid_pull_request_url, _url}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )

    write_evidence(context, evidence)
    opts = Keyword.put(validation_opts(), :origin_url, "https://gitlab.com/bjornjee/symphony.git")

    assert {:error, {:unsupported_repository_origin, _origin}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               opts
             )
  end

  test "rejects missing pull request URL", context do
    observed = observed_proofs(context.contract)
    evidence = Map.delete(valid_evidence(context, observed), "pull_request_url")
    write_evidence(context, evidence)

    assert {:error, :missing_pull_request_url} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )
  end

  test "rejects malformed and cross-repository pull request URLs", context do
    observed = observed_proofs(context.contract)

    for {url, expected_reason} <- [
          {"https://github.com/bjornjee/symphony/issues/42", :invalid_pull_request_url},
          {"https://github.com/other/project/pull/42", :pull_request_repository_mismatch}
        ] do
      write_evidence(context, %{valid_evidence(context, observed) | "pull_request_url" => url})

      assert {:error, {^expected_reason, _details}} =
               CompletionEvidence.validate(
                 context.workspace,
                 context.task,
                 context.contract,
                 observed,
                 validation_opts()
               )
    end
  end

  test "rejects a pull request URL that the repository host cannot resolve", context do
    observed = observed_proofs(context.contract)
    write_evidence(context, valid_evidence(context, observed))

    opts =
      Keyword.put(validation_opts(), :pull_request_verifier, fn _url, _workspace, _worker_host ->
        {:error, :not_found}
      end)

    assert {:error, {:pull_request_unavailable, :not_found}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               opts
             )
  end

  test "requires a prior failing RED event for fix workflow evidence", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)

    fix_plan = %{execution_plan() | "workflow" => "fix"}

    write_evidence(context, %{
      evidence
      | "workflow" => "fix",
        "workflow_proof" => %{"green_event_id" => "proof-1"}
    })

    assert {:error, :malformed_fix_workflow_proof} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               Keyword.put(validation_opts(), :execution_plan, fix_plan)
             )

    observed =
      Map.put(observed, "red-proof", %{
        exit_code: 1,
        sequence: 0,
        head_sha: String.duplicate("b", 40)
      })

    write_evidence(context, %{
      evidence
      | "workflow" => "fix",
        "workflow_proof" => %{
          "red_event_id" => "red-proof",
          "green_event_id" => "proof-1"
        }
    })

    assert {:ok, %{workflow: "fix"}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               Keyword.put(validation_opts(), :execution_plan, fix_plan)
             )
  end

  test "rejects proof captured before the final repository head", context do
    observed =
      context.contract
      |> observed_proofs()
      |> Map.update!("proof-1", &Map.put(&1, :head_sha, String.duplicate("b", 40)))

    write_evidence(context, valid_evidence(context, observed))

    assert {:error, {:stale_criterion_proof, _criterion, "proof-1", _old, @head_sha}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )
  end

  test "rejects a PR whose head differs from the reviewed repository head", context do
    observed = observed_proofs(context.contract)
    write_evidence(context, valid_evidence(context, observed))

    opts =
      Keyword.put(validation_opts(), :pull_request_verifier, fn url, _, _ ->
        {:ok, %{url: url, head_sha: String.duplicate("b", 40)}}
      end)

    assert {:error, {:pull_request_head_mismatch, @head_sha, _actual}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               opts
             )
  end

  test "accepts refactor baseline/final and chore validator workflow proofs", context do
    observed = observed_proofs(context.contract)

    refactor_observed =
      Map.put(observed, "baseline", %{
        exit_code: 0,
        sequence: 0,
        head_sha: String.duplicate("b", 40)
      })

    refactor_plan = %{execution_plan() | "workflow" => "refactor"}
    evidence = valid_evidence(context, observed)

    write_evidence(context, %{
      evidence
      | "workflow" => "refactor",
        "workflow_proof" => %{
          "baseline_event_id" => "baseline",
          "final_proof_event_id" => "proof-1"
        }
    })

    assert {:ok, %{workflow: "refactor"}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               refactor_observed,
               Keyword.put(validation_opts(), :execution_plan, refactor_plan)
             )

    chore_plan = %{execution_plan() | "workflow" => "chore"}

    write_evidence(context, %{
      evidence
      | "workflow" => "chore",
        "workflow_proof" => %{"validator_event_id" => "proof-1"}
    })

    assert {:ok, %{workflow: "chore"}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               Keyword.put(validation_opts(), :execution_plan, chore_plan)
             )

    write_evidence(context, %{
      evidence
      | "workflow" => "chore",
        "workflow_proof" => %{
          "surgical_review" => %{
            "reviewed_head_sha" => @head_sha,
            "record" => "Reviewed the final non-code diff."
          }
        }
    })

    assert {:ok, %{workflow: "chore"}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               Keyword.put(validation_opts(), :execution_plan, chore_plan)
             )
  end

  test "requires and accepts RED when a feature plan declares it", context do
    observed = observed_proofs(context.contract)
    red_plan = put_in(execution_plan(), ["candidate", "evidence_requirements"], ["Capture RED before GREEN"])
    evidence = valid_evidence(context, observed)
    write_evidence(context, evidence)

    assert {:error, :feature_red_evidence_missing} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               Keyword.put(validation_opts(), :execution_plan, red_plan)
             )

    observed = Map.put(observed, "feature-red", %{exit_code: 1, sequence: 0, head_sha: "old"})

    write_evidence(context, %{
      evidence
      | "workflow_proof" => %{
          "final_proof_event_id" => "proof-1",
          "red_event_id" => "feature-red"
        }
    })

    assert {:ok, %{workflow: "feature"}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               Keyword.put(validation_opts(), :execution_plan, red_plan)
             )
  end

  test "rejects execution-plan, workflow, and profile drift in the envelope", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)

    for {field, expected_reason} <- [
          {"execution_plan_digest", :completion_evidence_execution_plan_mismatch},
          {"workflow", :completion_evidence_workflow_mismatch},
          {"profile_digest", :completion_evidence_profile_mismatch}
        ] do
      write_evidence(context, Map.put(evidence, field, "drift"))

      assert {:error, {^expected_reason, _actual, _expected}} =
               CompletionEvidence.validate(
                 context.workspace,
                 context.task,
                 context.contract,
                 observed,
                 validation_opts()
               )
    end
  end

  test "resolves the PR URL and head through the real gh command boundary", context do
    observed = observed_proofs(context.contract)
    write_evidence(context, valid_evidence(context, observed))

    fake_bin = Path.join(context.workspace, "fake-bin-gh")
    fake_gh = Path.join(fake_bin, "gh")
    previous_path = System.get_env("PATH")
    File.mkdir_p!(fake_bin)

    File.write!(fake_gh, """
    #!/bin/sh
    printf '%s\n' '{"url":"#{@pr_url}","headRefOid":"#{@head_sha}"}'
    """)

    File.chmod!(fake_gh, 0o755)
    System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))

    on_exit(fn ->
      if previous_path, do: System.put_env("PATH", previous_path), else: System.delete_env("PATH")
    end)

    opts = Keyword.delete(validation_opts(), :pull_request_verifier)

    assert {:ok, %{pull_request_url: @pr_url}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               opts
             )
  end

  defp observed_proofs(contract) do
    contract.acceptance_criteria
    |> Enum.with_index(1)
    |> Map.new(fn {_criterion, index} ->
      {"proof-#{index}", %{exit_code: 0, sequence: index, head_sha: @head_sha}}
    end)
  end

  defp valid_evidence(context, observed) do
    proof_ids = Map.keys(observed) |> Enum.sort()

    criteria =
      context.contract.acceptance_criteria
      |> Enum.zip(proof_ids)
      |> Enum.map(fn {criterion, proof_id} ->
        %{
          "criterion_id" => criterion.id,
          "proof" => %{"kind" => "run_audit_command", "event_id" => proof_id}
        }
      end)

    %{
      "schema_version" => 2,
      "issue_id" => context.task.id,
      "issue_identifier" => context.task.identifier,
      "plan_digest" => context.contract.digest,
      "execution_plan_digest" => @execution_plan_digest,
      "workflow" => "feature",
      "profile_digest" => @profile_digest,
      "criteria" => criteria,
      "workflow_proof" => %{"final_proof_event_id" => hd(proof_ids)},
      "pull_request_url" => @pr_url,
      "pr_head_sha" => @head_sha,
      "repository_head_sha" => @head_sha
    }
  end

  defp write_evidence(context, evidence) do
    path = CompletionEvidence.path(context.workspace)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(evidence))
  end

  defp validation_opts do
    [
      origin_url: @origin_url,
      execution_plan: execution_plan(),
      repository_head_sha: @head_sha,
      pull_request_verifier: fn url, _workspace, _worker_host ->
        {:ok, %{url: url, head_sha: @head_sha}}
      end
    ]
  end

  defp execution_plan do
    %{
      "plan_digest" => @execution_plan_digest,
      "workflow" => "feature",
      "profile_digest" => @profile_digest,
      "candidate" => %{"evidence_requirements" => []}
    }
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
