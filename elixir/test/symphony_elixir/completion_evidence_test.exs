defmodule SymphonyElixir.CompletionEvidenceTest do
  use ExUnit.Case

  alias SymphonyElixir.Linear.TaskContract

  alias SymphonyElixir.{
    CompletionEvidence,
    ExecutionLedger,
    RepositoryFingerprint,
    TaskContractFixtures
  }

  setup do
    root = Path.join(System.tmp_dir!(), "trusted-completion-#{System.os_time(:nanosecond)}")
    workspace = Path.join(root, "repo")
    File.mkdir_p!(workspace)
    System.cmd("git", ["init", "-q", workspace])
    System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", workspace, "config", "user.name", "Test"])
    System.cmd("git", ["-C", workspace, "remote", "add", "origin", "git@github.com:acme/repo.git"])
    File.write!(Path.join(workspace, "README.md"), "done\n")
    System.cmd("git", ["-C", workspace, "add", "README.md"])
    System.cmd("git", ["-C", workspace, "commit", "-qm", "chore: done"])
    {:ok, state} = RepositoryFingerprint.capture(workspace)
    Application.put_env(:symphony_elixir, :execution_state_root, Path.join(root, "ledger"))

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :execution_state_root)
      File.rm_rf(root)
    end)

    issue = TaskContractFixtures.issue()
    {:ok, contract} = TaskContract.from_issue(issue)

    plan = %{
      "plan_digest" => String.duplicate("a", 64),
      "instruction_digest" => String.duplicate("b", 64),
      "profile_digest" => String.duplicate("c", 64),
      "workflow" => "feature",
      "repository" => %{"origin" => state.origin, "base_sha" => state.base_sha}
    }

    key = ExecutionLedger.key("origin", issue.id, plan["plan_digest"])
    criteria = Enum.map(contract.acceptance_criteria, &%{"criterion_id" => &1.id, "proof_receipt_digest" => String.duplicate("d", 64), "proof_id" => "final"})

    {:ok, evidence} =
      ExecutionLedger.create(key, "completion", "evidence", %{
        "schema_version" => 3,
        "issue_id" => issue.id,
        "issue_identifier" => issue.identifier,
        "contract_digest" => contract.digest,
        "execution_plan_digest" => plan["plan_digest"],
        "instruction_digest" => plan["instruction_digest"],
        "profile_digest" => plan["profile_digest"],
        "workflow" => plan["workflow"],
        "repository_head_sha" => state.base_sha,
        "pr_head_sha" => state.base_sha,
        "pr_head_branch" => "feature/sym-1-test",
        "pr_base_branch" => "main",
        "pull_request_url" => "https://github.com/acme/repo/pull/1",
        "criteria" => criteria
      })

    remote_pr = %{
      "url" => "https://github.com/acme/repo/pull/1",
      "head_sha" => state.base_sha,
      "head_branch" => "feature/sym-1-test",
      "base_branch" => "main",
      "state" => "OPEN",
      "is_cross_repository" => false
    }

    %{
      workspace: workspace,
      issue: issue,
      contract: contract,
      plan: plan,
      key: key,
      evidence: evidence,
      remote_pr: remote_pr
    }
  end

  test "accepts only ledger-derived evidence", ctx do
    assert {:ok, validated} =
             CompletionEvidence.validate(ctx.workspace, ctx.issue, ctx.contract, %{}, validation_opts(ctx))

    assert validated.artifact_digest == ctx.evidence["receipt_digest"]
  end

  test "loads the sealed plan from the workspace when it is not injected", ctx do
    plan_path = SymphonyElixir.PlanningArtifact.execution_plan_path(ctx.workspace)
    File.mkdir_p!(Path.dirname(plan_path))
    File.write!(plan_path, Jason.encode!(ctx.plan))

    assert {:ok, validated} =
             CompletionEvidence.validate(
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               %{},
               execution_ledger_key: ctx.key,
               pull_request_reader: reader(ctx.remote_pr)
             )

    assert validated.execution_plan_digest == ctx.plan["plan_digest"]
    assert CompletionEvidence.path(ctx.workspace) =~ ".symphony/completion-evidence.json"
  end

  test "rejects workspace-only and stale evidence", ctx do
    assert {:error, :trusted_execution_ledger_key_missing} =
             CompletionEvidence.validate(ctx.workspace, ctx.issue, ctx.contract, %{})

    assert {:error, :trusted_execution_ledger_key_missing} = CompletionEvidence.validate(ctx.workspace, ctx.issue, ctx.contract, %{}, execution_plan: ctx.plan)
    stale = %{ctx.plan | "instruction_digest" => String.duplicate("f", 64)}

    assert {:error, :completion_evidence_instruction_mismatch} =
             CompletionEvidence.validate(
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               %{},
               validation_opts(ctx, execution_plan: stale)
             )
  end

  test "rejects a missing or unreadable sealed execution plan", ctx do
    assert {:error, :execution_plan_missing} =
             CompletionEvidence.validate(ctx.workspace, ctx.issue, ctx.contract, %{}, execution_ledger_key: ctx.key)

    path = SymphonyElixir.PlanningArtifact.execution_plan_path(ctx.workspace)
    File.mkdir_p!(path)

    assert {:error, {:execution_plan_invalid, {:artifact_read_failed, ^path, _reason}}} =
             CompletionEvidence.validate(ctx.workspace, ctx.issue, ctx.contract, %{}, execution_ledger_key: ctx.key)
  end

  test "rejects a trusted receipt whose PR belongs to another repository", ctx do
    key = ExecutionLedger.key("other", ctx.issue.id, ctx.plan["plan_digest"])

    payload =
      ctx.evidence
      |> Map.drop(["receipt_digest"])
      |> Map.put("pull_request_url", "https://github.com/other/repo/pull/1")

    assert {:ok, _receipt} = ExecutionLedger.create(key, "completion", "evidence", payload)

    assert {:error, :completion_evidence_repository_mismatch} =
             CompletionEvidence.validate(ctx.workspace, ctx.issue, ctx.contract, %{},
               execution_plan: ctx.plan,
               execution_ledger_key: key
             )
  end

  test "rejects malformed criteria and invalid PR URLs", ctx do
    malformed_key = ExecutionLedger.key("malformed", ctx.issue.id, ctx.plan["plan_digest"])

    malformed =
      ctx.evidence
      |> Map.drop(["receipt_digest"])
      |> Map.put("criteria", nil)

    assert {:ok, _} = ExecutionLedger.create(malformed_key, "completion", "evidence", malformed)

    assert {:error, :completion_evidence_criteria_malformed} =
             CompletionEvidence.validate(ctx.workspace, ctx.issue, ctx.contract, %{},
               execution_plan: ctx.plan,
               execution_ledger_key: malformed_key,
               pull_request_reader: reader(ctx.remote_pr)
             )

    invalid_url_key = ExecutionLedger.key("invalid-url", ctx.issue.id, ctx.plan["plan_digest"])

    invalid_url =
      ctx.evidence
      |> Map.drop(["receipt_digest"])
      |> Map.put("pull_request_url", "http://github.com/acme/repo/pull/1")

    assert {:ok, _} = ExecutionLedger.create(invalid_url_key, "completion", "evidence", invalid_url)

    assert {:error, :completion_evidence_pr_invalid} =
             CompletionEvidence.validate(ctx.workspace, ctx.issue, ctx.contract, %{},
               execution_plan: ctx.plan,
               execution_ledger_key: invalid_url_key
             )
  end

  test "accepts an HTTPS repository origin", ctx do
    plan = put_in(ctx.plan, ["repository", "origin"], "https://github.com/acme/repo.git")

    assert {:ok, _validated} =
             CompletionEvidence.validate(ctx.workspace, ctx.issue, ctx.contract, %{},
               execution_plan: plan,
               execution_ledger_key: ctx.key,
               pull_request_reader: reader(ctx.remote_pr)
             )
  end

  test "rejects a remotely closed pull request", ctx do
    assert {:error, :completion_evidence_pr_not_open} =
             CompletionEvidence.validate(
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               %{},
               validation_opts(ctx, pull_request_reader: reader(%{ctx.remote_pr | "state" => "CLOSED"}))
             )
  end

  test "rejects a remotely changed pull request head", ctx do
    stale = %{ctx.remote_pr | "head_sha" => String.duplicate("0", 40)}

    assert {:error, :completion_evidence_remote_head_stale} =
             CompletionEvidence.validate(
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               %{},
               validation_opts(ctx, pull_request_reader: reader(stale))
             )
  end

  test "rejects a remotely changed pull request branch", ctx do
    changed = %{ctx.remote_pr | "head_branch" => "feature/other"}

    assert {:error, :completion_evidence_remote_branch_mismatch} =
             CompletionEvidence.validate(
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               %{},
               validation_opts(ctx, pull_request_reader: reader(changed))
             )
  end

  test "rejects a remotely retargeted pull request", ctx do
    retargeted = %{ctx.remote_pr | "base_branch" => "release"}

    assert {:error, :completion_evidence_remote_base_mismatch} =
             CompletionEvidence.validate(
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               %{},
               validation_opts(ctx, pull_request_reader: reader(retargeted))
             )
  end

  test "rejects a cross-repository pull request", ctx do
    cross_repository = %{ctx.remote_pr | "is_cross_repository" => true}

    assert {:error, :completion_evidence_cross_repository_pr} =
             CompletionEvidence.validate(
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               %{},
               validation_opts(ctx, pull_request_reader: reader(cross_repository))
             )
  end

  test "rejects a non-string PR URL and a plan without repository authority", ctx do
    key = ExecutionLedger.key("bad-shape", ctx.issue.id, ctx.plan["plan_digest"])

    payload =
      ctx.evidence
      |> Map.drop(["receipt_digest"])
      |> Map.put("pull_request_url", nil)

    assert {:ok, _} = ExecutionLedger.create(key, "completion", "evidence", payload)

    assert {:error, :completion_evidence_pr_invalid} =
             CompletionEvidence.validate(ctx.workspace, ctx.issue, ctx.contract, %{},
               execution_plan: Map.delete(ctx.plan, "repository"),
               execution_ledger_key: key
             )
  end

  defp validation_opts(ctx, overrides \\ []) do
    Keyword.merge(
      [
        execution_plan: ctx.plan,
        execution_ledger_key: ctx.key,
        pull_request_reader: reader(ctx.remote_pr)
      ],
      overrides
    )
  end

  defp reader(pull_request) do
    fn _workspace, _plan, _url, _opts -> {:ok, pull_request} end
  end
end
