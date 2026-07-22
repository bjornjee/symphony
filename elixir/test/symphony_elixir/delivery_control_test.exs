defmodule SymphonyElixir.DeliveryControlTest do
  use ExUnit.Case

  alias SymphonyElixir.Linear.TaskContract

  alias SymphonyElixir.{
    CompletionEvidence,
    DeliveryControl,
    ExecutionLedger,
    RepositoryFingerprint,
    TaskContractFixtures
  }

  setup do
    root = Path.join(System.tmp_dir!(), "delivery-control-#{System.os_time(:nanosecond)}")
    workspace = Path.join(root, "repo")
    File.mkdir_p!(workspace)
    git(workspace, ["init", "-q", "-b", "main"])
    git(workspace, ["config", "user.email", "test@example.com"])
    git(workspace, ["config", "user.name", "Test"])
    git(workspace, ["remote", "add", "origin", "git@github.com:acme/repo.git"])
    File.write!(Path.join(workspace, "README.md"), "base\n")
    git(workspace, ["add", "README.md"])
    git(workspace, ["commit", "-qm", "chore: base"])
    {base, 0} = git(workspace, ["rev-parse", "HEAD"])

    issue = TaskContractFixtures.issue(%{title: "chore: finish delivery"})
    {:ok, contract} = TaskContract.from_issue(issue)
    task_branch = "chore/#{String.downcase(issue.identifier)}-chore-finish-delivery"
    git(workspace, ["switch", "-qc", task_branch])
    File.write!(Path.join(workspace, "README.md"), "done\n")
    git(workspace, ["add", "README.md"])
    git(workspace, ["commit", "-qm", "chore: finish delivery"])
    {:ok, state} = RepositoryFingerprint.capture(workspace)
    Application.put_env(:symphony_elixir, :execution_state_root, Path.join(root, "ledger"))

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :execution_state_root)
      File.rm_rf(root)
    end)

    criterion_ids = Enum.map(contract.acceptance_criteria, & &1.id)

    plan = %{
      "plan_digest" => String.duplicate("a", 64),
      "instruction_digest" => String.duplicate("b", 64),
      "profile_digest" => String.duplicate("c", 64),
      "workflow" => "chore",
      "candidate" => %{
        "repository" => %{"origin" => state.origin, "base_sha" => String.trim(base)},
        "affected_paths" => ["README.md"],
        "verification_profile" => "Surgical",
        "ordered_steps" => [%{"id" => "deliver", "proof_ids" => ["final"], "affected_paths" => ["README.md"], "depends_on" => []}],
        "proofs" => [%{"id" => "final", "role" => "final", "command" => "mix test", "criterion_ids" => criterion_ids}]
      }
    }

    key = ExecutionLedger.key(state.origin, issue.id, plan["plan_digest"])

    {:ok, final} =
      ExecutionLedger.create(key, "proof", "final-1", %{
        "proof_id" => "final",
        "role" => "final",
        "passed" => true,
        "criterion_ids" => criterion_ids,
        "after_state_digest" => state.digest,
        "head_sha" => state.base_sha
      })

    {:ok, _} = ExecutionLedger.create(key, "phase", "deliver", %{"phase_id" => "deliver"})
    {:ok, review} = ExecutionLedger.create(key, "implementation-review", "review-1", %{"verdict" => "approve", "head_sha" => state.base_sha, "repository_state_digest" => state.digest})

    %{
      workspace: workspace,
      issue: issue,
      contract: contract,
      plan: plan,
      key: key,
      state: state,
      final: final,
      review: review
    }
  end

  test "publishes through the engine and derives immutable completion evidence", ctx do
    publisher = fn _workspace, _plan, _title, _body, _opts ->
      {:ok,
       %{
         "url" => "https://github.com/acme/repo/pull/1",
         "head_sha" => ctx.state.base_sha,
         "head_branch" => "chore/#{String.downcase(ctx.issue.identifier)}-chore-finish-delivery",
         "base_branch" => "main",
         "origin" => ctx.state.origin
       }}
    end

    assert {:ok, evidence} =
             DeliveryControl.publish(ctx.workspace, ctx.issue, ctx.contract, ctx.plan, ctx.key, "chore: finish delivery", "## Why\nx\n## Summary\nx\n## Test plan\nmix test", publisher: publisher)

    assert evidence["schema_version"] == 3
    assert evidence["pull_request_url"] == "https://github.com/acme/repo/pull/1"
    assert is_binary(evidence["surgical_review_receipt_digest"])
    assert {:ok, ^evidence} = DeliveryControl.read_completion(ctx.key)

    assert {:ok, validated} =
             CompletionEvidence.validate(ctx.workspace, ctx.issue, ctx.contract, %{},
               execution_plan: ctx.plan,
               execution_ledger_key: ctx.key,
               pull_request_reader: fn _workspace, _plan, _url, _opts ->
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
             )

    assert validated.pull_request_url == evidence["pull_request_url"]

    assert {:ok, ^evidence} =
             DeliveryControl.publish(
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               ctx.plan,
               ctx.key,
               "chore: finish delivery",
               "## Why\nx\n## Summary\nx\n## Test plan\nmix test",
               publisher: publisher
             )

    assert %{"success" => true} =
             DeliveryControl.execute_tool(
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               ctx.plan,
               ctx.key,
               "publish_pull_request",
               %{
                 "title" => "chore: finish delivery",
                 "body" => "## Why\nx\n## Summary\nx\n## Test plan\nmix test"
               },
               publisher: publisher
             )

    assert %{"success" => false} =
             DeliveryControl.execute_tool(
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               ctx.plan,
               ctx.key,
               "unsupported",
               %{},
               []
             )
  end

  test "rejects source edits after final proof and review", ctx do
    File.write!(Path.join(ctx.workspace, "README.md"), "changed after review\n")

    assert {:error, :delivery_requires_clean_tree} =
             DeliveryControl.publish(
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               ctx.plan,
               ctx.key,
               "chore: finish delivery",
               "## Why\nx\n## Summary\nx\n## Test plan\nmix test",
               publisher: fn _, _, _, _, _ -> flunk("publisher must not run") end
             )
  end

  test "publishes and writes trusted evidence through the SSH worker boundary", ctx do
    fake_bin = Path.join(Path.dirname(ctx.workspace), "fake-bin")
    fake_ssh = Path.join(fake_bin, "ssh")
    previous_path = System.get_env("PATH")
    File.mkdir_p!(fake_bin)

    File.write!(fake_ssh, """
    #!/bin/sh
    for arg in "$@"; do remote_command="$arg"; done
    eval "$remote_command"
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))

    on_exit(fn ->
      if previous_path, do: System.put_env("PATH", previous_path), else: System.delete_env("PATH")
    end)

    publisher = fn _workspace, _plan, _title, _body, opts ->
      assert opts[:worker_host] == "worker-a"

      {:ok,
       %{
         "url" => "https://github.com/acme/repo/pull/1",
         "head_sha" => ctx.state.base_sha,
         "head_branch" => "chore/#{String.downcase(ctx.issue.identifier)}-chore-finish-delivery",
         "base_branch" => "main",
         "origin" => ctx.state.origin
       }}
    end

    assert {:ok, evidence} =
             DeliveryControl.publish(
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               ctx.plan,
               ctx.key,
               "chore: finish delivery",
               "## Why\nx\n## Summary\nx\n## Test plan\nmix test",
               publisher: publisher,
               worker_host: "worker-a"
             )

    assert evidence["pr_head_sha"] == ctx.state.base_sha
  end

  test "workspace JSON cannot forge trusted completion evidence", ctx do
    File.mkdir_p!(Path.join(ctx.workspace, ".symphony"))
    File.write!(Path.join([ctx.workspace, ".symphony", "completion-evidence.json"]), "{}")

    publisher = fn _, _, _, _, _ ->
      {:ok,
       %{
         "url" => "https://github.com/acme/repo/pull/1",
         "head_sha" => ctx.state.base_sha,
         "head_branch" => "chore/#{String.downcase(ctx.issue.identifier)}-chore-finish-delivery",
         "base_branch" => "main",
         "origin" => ctx.state.origin
       }}
    end

    assert {:error, :workspace_completion_evidence_collision} =
             DeliveryControl.publish(ctx.workspace, ctx.issue, ctx.contract, ctx.plan, ctx.key, "chore: finish delivery", "## Why\nx\n## Summary\nx\n## Test plan\nmix test", publisher: publisher)
  end

  test "rejects completion when no fresh final proof covers a criterion", ctx do
    key = ExecutionLedger.key(ctx.state.origin, ctx.issue.id, "missing-criterion")

    assert {:ok, _} =
             ExecutionLedger.create(key, "proof", "final-1", %{
               "proof_id" => "final",
               "role" => "final",
               "passed" => true,
               "criterion_ids" => [],
               "after_state_digest" => ctx.state.digest,
               "head_sha" => ctx.state.base_sha
             })

    assert {:ok, _} = ExecutionLedger.create(key, "phase", "deliver", %{"phase_id" => "deliver"})

    assert {:ok, _} =
             ExecutionLedger.create(key, "implementation-review", "review-1", %{
               "verdict" => "approve",
               "head_sha" => ctx.state.base_sha,
               "repository_state_digest" => ctx.state.digest
             })

    publisher = fn _, _, _, _, _ ->
      {:ok,
       %{
         "url" => "https://github.com/acme/repo/pull/1",
         "head_sha" => ctx.state.base_sha,
         "head_branch" => "chore/#{String.downcase(ctx.issue.identifier)}-chore-finish-delivery",
         "base_branch" => "main",
         "origin" => ctx.state.origin
       }}
    end

    assert {:error, {:criterion_without_fresh_final_proof, _criterion_id}} =
             DeliveryControl.publish(
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               ctx.plan,
               key,
               "chore: finish delivery",
               "## Why\nx\n## Summary\nx\n## Test plan\nmix test",
               publisher: publisher
             )
  end

  test "reports corrupted completion receipts", ctx do
    key = ExecutionLedger.key(ctx.state.origin, ctx.issue.id, "corrupt-completion")
    path = ExecutionLedger.path(key, "completion", "evidence")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{}")

    assert {:error, {:completion_evidence_invalid, :invalid_receipt}} =
             DeliveryControl.read_completion(key)
  end

  defp git(workspace, args), do: System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true)
end
