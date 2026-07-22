defmodule SymphonyElixir.ImplementationReviewTest do
  use ExUnit.Case

  alias SymphonyElixir.{ExecutionLedger, ImplementationReview}
  alias SymphonyElixir.Linear.TaskContract
  alias SymphonyElixir.{RepositoryFingerprint, TaskContractFixtures}

  setup do
    root = Path.join(System.tmp_dir!(), "implementation-review-#{System.os_time(:nanosecond)}")
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
    git(workspace, ["switch", "-qc", "chore/sym-1-review"])
    File.write!(Path.join(workspace, "README.md"), "changed\n")
    git(workspace, ["add", "README.md"])
    git(workspace, ["commit", "-qm", "chore: update readme"])
    {:ok, state} = RepositoryFingerprint.capture(workspace)

    Application.put_env(:symphony_elixir, :execution_state_root, Path.join(root, "ledger"))

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :execution_state_root)
      File.rm_rf(root)
    end)

    issue = TaskContractFixtures.issue(%{title: "chore: update readme"})
    {:ok, contract} = TaskContract.from_issue(issue)

    plan = %{
      "plan_digest" => String.duplicate("a", 64),
      "instruction_digest" => String.duplicate("b", 64),
      "profile_digest" => String.duplicate("c", 64),
      "workflow" => "chore",
      "candidate" => %{
        "repository" => %{"origin" => state.origin, "base_sha" => String.trim(base)},
        "affected_paths" => ["README.md"],
        "execution_context" => "test-only",
        "scale_shape" => "one file",
        "ordered_steps" => [%{"id" => "change", "proof_ids" => ["final"], "affected_paths" => ["README.md"], "depends_on" => []}],
        "proofs" => [%{"id" => "final", "role" => "final"}]
      }
    }

    key = ExecutionLedger.key(state.origin, issue.id, plan["plan_digest"])

    {:ok, _proof} =
      ExecutionLedger.create(key, "proof", "final-1", %{
        "proof_id" => "final",
        "role" => "final",
        "passed" => true,
        "after_state_digest" => state.digest,
        "head_sha" => state.base_sha,
        "output_hash" => String.duplicate("d", 64)
      })

    {:ok, _phase} = ExecutionLedger.create(key, "phase", "change", %{"phase_id" => "change"})
    %{workspace: workspace, issue: issue, contract: contract, plan: plan, key: key, state: state}
  end

  test "runs a medium read-only reviewer and binds approval to the exact final state", ctx do
    parent = self()

    run_turn = fn _session, _prompt, _issue, opts ->
      send(parent, {:review_opts, opts})
      assert %{"success" => true} = opts[:tool_executor].("submit_implementation_review", %{"verdict" => "approve", "blocking_findings" => [], "advisory_findings" => []})
      {:ok, %{turn_id: "review"}}
    end

    assert {:ok, approval} =
             ImplementationReview.request(ctx.workspace, ctx.issue, ctx.contract, ctx.plan, ctx.key,
               start_session: fn _, opts ->
                 assert opts[:dynamic_tools] == ImplementationReview.submission_tool_specs()
                 {:ok, %{thread_id: "review-thread"}}
               end,
               run_turn: run_turn,
               stop_session: fn _ -> :ok end
             )

    assert approval["head_sha"] == ctx.state.base_sha
    assert {:ok, ^approval} = ImplementationReview.latest_approval(ctx.key, ctx.state.base_sha, ctx.state.digest)
    assert_receive {:review_opts, opts}
    assert opts[:effort] == "medium"
    assert opts[:sandbox_policy] == %{"type" => "readOnly", "networkAccess" => false}
  end

  test "third revision invokes exhaustion exactly once", ctx do
    counter = Agent.start_link(fn -> 0 end) |> elem(1)

    run_turn = fn _session, _prompt, _issue, opts ->
      opts[:tool_executor].("submit_implementation_review", %{"verdict" => "revise", "blocking_findings" => ["Fix it"], "advisory_findings" => []})
      {:ok, %{}}
    end

    common = [
      start_session: fn _, _ -> {:ok, %{thread_id: "review-thread"}} end,
      run_turn: run_turn,
      stop_session: fn _ -> :ok end,
      exhausted_handler: fn _, _, _, _ ->
        Agent.update(counter, &(&1 + 1))
        {:error, :exhausted}
      end
    ]

    assert {:ok, %{"verdict" => "revise"}} = ImplementationReview.request(ctx.workspace, ctx.issue, ctx.contract, ctx.plan, ctx.key, common)
    assert {:ok, %{"verdict" => "revise"}} = ImplementationReview.request(ctx.workspace, ctx.issue, ctx.contract, ctx.plan, ctx.key, common)
    assert {:error, :exhausted} = ImplementationReview.request(ctx.workspace, ctx.issue, ctx.contract, ctx.plan, ctx.key, common)
    assert Agent.get(counter, & &1) == 1
  end

  test "a later revise verdict supersedes an earlier approval", ctx do
    {:ok, _approval} =
      ExecutionLedger.create(ctx.key, "implementation-review", "review-1", %{
        "verdict" => "approve",
        "head_sha" => ctx.state.base_sha,
        "repository_state_digest" => ctx.state.digest
      })

    {:ok, _revision} =
      ExecutionLedger.create(ctx.key, "implementation-review", "review-2", %{
        "verdict" => "revise",
        "head_sha" => ctx.state.base_sha,
        "repository_state_digest" => ctx.state.digest
      })

    assert {:error, :implementation_review_revision_required} =
             ImplementationReview.latest_approval(ctx.key, ctx.state.base_sha, ctx.state.digest)
  end

  test "rejects a reviewer file-change event without persisting approval", ctx do
    run_turn = fn _session, _prompt, _issue, opts ->
      opts[:on_message].(%{
        payload: %{
          "method" => "item/completed",
          "params" => %{"item" => %{"type" => "fileChange"}}
        }
      })

      opts[:tool_executor].("submit_implementation_review", %{
        "verdict" => "approve",
        "blocking_findings" => [],
        "advisory_findings" => []
      })

      {:ok, %{}}
    end

    assert {:error, :implementation_review_file_change} =
             ImplementationReview.request(ctx.workspace, ctx.issue, ctx.contract, ctx.plan, ctx.key,
               start_session: fn _, _ -> {:ok, %{thread_id: "review-thread"}} end,
               run_turn: run_turn,
               stop_session: fn _ -> :ok end
             )

    assert {:ok, []} = ExecutionLedger.list(ctx.key, "implementation-review")
  end

  test "approval is stale after a later commit", ctx do
    assert {:ok, _approval} =
             ExecutionLedger.create(ctx.key, "implementation-review", "review-1", %{
               "verdict" => "approve",
               "head_sha" => ctx.state.base_sha,
               "repository_state_digest" => ctx.state.digest
             })

    File.write!(Path.join(ctx.workspace, "README.md"), "reviewed then changed\n")
    git(ctx.workspace, ["commit", "-qam", "chore: revise after review"])
    {:ok, current} = RepositoryFingerprint.capture(ctx.workspace)

    assert {:error, :implementation_review_approval_stale} =
             ImplementationReview.latest_approval(ctx.key, current.base_sha, current.digest)
  end

  test "rejects malformed or duplicate reviewer submissions", ctx do
    run_turn = fn _session, _prompt, _issue, opts ->
      assert %{"success" => false} = opts[:tool_executor].("unsupported", %{})

      assert %{"success" => true} =
               opts[:tool_executor].("submit_implementation_review", %{"verdict" => "approve"})

      assert %{"success" => false} =
               opts[:tool_executor].("submit_implementation_review", %{
                 "verdict" => "approve",
                 "blocking_findings" => [],
                 "advisory_findings" => []
               })

      {:ok, %{}}
    end

    assert {:error, :invalid_implementation_review_fields} =
             ImplementationReview.request(ctx.workspace, ctx.issue, ctx.contract, ctx.plan, ctx.key,
               start_session: fn _, _ -> {:ok, %{thread_id: "review-thread"}} end,
               run_turn: run_turn,
               stop_session: fn _ -> :ok end
             )

    assert ImplementationReview.required?(ctx.plan)

    refute ImplementationReview.required?(%{
             "execution_mode" => "simple",
             "verification_profile" => "Targeted"
           })
  end

  defp git(workspace, args), do: System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true)
end
