defmodule SymphonyElixir.EnginePublisherTest do
  use ExUnit.Case

  alias SymphonyElixir.EnginePublisher

  setup do
    root = Path.join(System.tmp_dir!(), "engine-publisher-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(root)
    git(root, ["init", "-q", "-b", "main"])
    git(root, ["config", "user.email", "test@example.com"])
    git(root, ["config", "user.name", "Test"])
    git(root, ["remote", "add", "origin", "git@github.com:acme/repo.git"])
    File.write!(Path.join(root, "README.md"), "base\n")
    git(root, ["add", "README.md"])
    git(root, ["commit", "-qm", "chore: base"])
    {base, 0} = git(root, ["rev-parse", "HEAD"])
    git(root, ["update-ref", "refs/remotes/origin/main", String.trim(base)])
    git(root, ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
    git(root, ["switch", "-qc", "feature/sym-1-test"])
    File.write!(Path.join(root, "README.md"), "changed\n")
    git(root, ["add", "README.md"])
    git(root, ["commit", "-qm", "feat: change readme"])
    {head, 0} = git(root, ["rev-parse", "HEAD"])

    plan = %{
      "workflow" => "feature",
      "repository" => %{"origin" => "git@github.com:acme/repo.git", "base_sha" => String.trim(base)},
      "proofs" => [%{"command" => "mix test test/example_test.exs"}]
    }

    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: root, plan: plan, head: String.trim(head)}
  end

  test "pushes normally, creates one PR, and verifies exact readback head", ctx do
    parent = self()

    runner = fn workspace, _host, executable, args ->
      send(parent, {:command, executable, args})

      case {executable, args} do
        {"git", ["-C", ^workspace, "push", "origin", "feature/sym-1-test"]} ->
          {:ok, {"", 0}}

        {"gh", ["pr", "list" | _]} ->
          {:ok, {"[]", 0}}

        {"gh", ["pr", "create" | _]} ->
          {:ok, {"https://github.com/acme/repo/pull/1\n", 0}}

        {"gh", ["pr", "view" | _]} ->
          {:ok, {Jason.encode!(readback(ctx)), 0}}

        {"git", ["-C", ^workspace | git_args]} ->
          {:ok, System.cmd("git", ["-C", workspace | git_args], stderr_to_stdout: true)}
      end
    end

    assert {:ok, published} = EnginePublisher.publish(ctx.workspace, ctx.plan, "feat: change readme", body(), command_runner: runner)
    assert published["head_sha"] == ctx.head
    assert_receive {:command, "git", ["-C", _, "push", "origin", "feature/sym-1-test"]}
  end

  test "reads back the current pull request identity", ctx do
    assert {:ok, pull_request} =
             EnginePublisher.read_pull_request(
               ctx.workspace,
               ctx.plan,
               "https://github.com/acme/repo/pull/1",
               command_runner: publishing_runner(ctx, readback(ctx))
             )

    assert pull_request["head_sha"] == ctx.head
    assert pull_request["head_branch"] == "feature/sym-1-test"
    assert pull_request["base_branch"] == "main"
    assert pull_request["state"] == "OPEN"
  end

  test "rejects a closed pull request readback", ctx do
    closed = %{readback(ctx) | "state" => "CLOSED"}

    assert {:error, :published_pull_request_not_open} =
             EnginePublisher.publish(
               ctx.workspace,
               ctx.plan,
               "feat: change readme",
               body(),
               command_runner: publishing_runner(ctx, closed)
             )
  end

  test "rejects a cross-repository pull request readback", ctx do
    cross_repository = %{readback(ctx) | "isCrossRepository" => true}

    assert {:error, :published_cross_repository_pull_request} =
             EnginePublisher.publish(
               ctx.workspace,
               ctx.plan,
               "feat: change readme",
               body(),
               command_runner: publishing_runner(ctx, cross_repository)
             )
  end

  test "rejects a nonconventional pull request title", ctx do
    assert {:error, :invalid_pull_request_title} = EnginePublisher.publish(ctx.workspace, ctx.plan, "Bad title", "body")
  end

  test "rejects tool self-attribution", ctx do
    attributed_body = String.replace(body(), "Needed.", "Generated with Codex")

    assert {:error, :pull_request_self_attribution} =
             EnginePublisher.publish(ctx.workspace, ctx.plan, "feat: change readme", attributed_body)
  end

  test "rejects an incomplete pull request body", ctx do
    assert {:error, :invalid_pull_request_body} =
             EnginePublisher.publish(
               ctx.workspace,
               ctx.plan,
               "feat: change readme",
               String.replace(body(), "#### Alternatives\n\n- None considered.\n\n", "")
             )
  end

  test "rejects the legacy body that repository CI cannot validate", ctx do
    legacy_body = "## Why\nNeeded.\n\n## Summary\nChange.\n\n## Test plan\n`mix test test/example_test.exs`"

    assert {:error, :invalid_pull_request_body} =
             EnginePublisher.publish(ctx.workspace, ctx.plan, "feat: change readme", legacy_body)
  end

  test "rejects a test plan that omits an approved proof", ctx do
    assert {:error, :pull_request_test_plan_mismatch} =
             EnginePublisher.publish(
               ctx.workspace,
               ctx.plan,
               "feat: change readme",
               String.replace(body(), "mix test test/example_test.exs", "not the approved proof")
             )
  end

  test "rejects origin, branch, ancestry, and commit drift before pushing", ctx do
    assert {:error, :publication_origin_drift} =
             EnginePublisher.publish(
               ctx.workspace,
               put_in(ctx.plan, ["repository", "origin"], "git@github.com:other/repo.git"),
               "feat: change readme",
               body()
             )

    git(ctx.workspace, ["switch", "-qc", "unrelated"])

    assert {:error, :invalid_task_branch} =
             EnginePublisher.publish(ctx.workspace, ctx.plan, "feat: change readme", body())
  end

  test "rejects nonconventional commits", ctx do
    File.write!(Path.join(ctx.workspace, "SECOND.md"), "bad\n")
    git(ctx.workspace, ["add", "SECOND.md"])
    git(ctx.workspace, ["commit", "-qm", "bad subject"])

    assert {:error, :nonconventional_commit} =
             EnginePublisher.publish(
               ctx.workspace,
               ctx.plan,
               "feat: change readme",
               body(),
               command_runner: publishing_runner(ctx, readback(ctx))
             )
  end

  test "rejects cross-repository and stale PR readback", ctx do
    cross_repo = %{readback(ctx) | "url" => "https://github.com/other/repo/pull/1"}

    assert {:error, :published_repository_mismatch} =
             EnginePublisher.publish(
               ctx.workspace,
               ctx.plan,
               "feat: change readme",
               body(),
               command_runner: publishing_runner(ctx, cross_repo)
             )

    stale = %{readback(ctx) | "headRefOid" => String.duplicate("0", 40)}

    assert {:error, {:published_head_mismatch, _, _}} =
             EnginePublisher.publish(
               ctx.workspace,
               ctx.plan,
               "feat: change readme",
               body(),
               command_runner: publishing_runner(ctx, stale)
             )
  end

  test "updates the one existing branch PR and verifies it", ctx do
    parent = self()
    existing = [%{"url" => "https://github.com/acme/repo/pull/1"}]
    runner = publishing_runner(ctx, readback(ctx), existing, parent)

    assert {:ok, _published} =
             EnginePublisher.publish(
               ctx.workspace,
               ctx.plan,
               "feat: change readme",
               body(),
               command_runner: runner
             )

    assert_receive {:command, "gh", ["pr", "edit" | _]}
  end

  test "supports an HTTPS origin and candidate-shaped approved plan", ctx do
    git(ctx.workspace, ["remote", "set-url", "origin", "https://github.com/acme/repo.git"])

    plan = %{
      "workflow" => "feature",
      "candidate" => %{
        "repository" => %{
          "origin" => "https://github.com/acme/repo.git",
          "base_sha" => ctx.plan["repository"]["base_sha"]
        },
        "proofs" => ctx.plan["proofs"]
      }
    }

    assert {:ok, _published} =
             EnginePublisher.publish(
               ctx.workspace,
               plan,
               "feat: change readme",
               body(),
               command_runner: publishing_runner(ctx, readback(ctx))
             )
  end

  test "runs GitHub API commands on the controller for a remote workspace", ctx do
    parent = self()

    remote_runner = fn workspace, host, executable, args ->
      send(parent, {:remote_command, host, executable, args})

      case {executable, args} do
        {"git", ["-C", ^workspace, "push", "origin", "feature/sym-1-test"]} ->
          {:ok, {"", 0}}

        {"git", ["-C", ^workspace | git_args]} ->
          {:ok, System.cmd("git", ["-C", workspace | git_args], stderr_to_stdout: true)}
      end
    end

    controller_runner = fn _workspace, host, "gh", args ->
      send(parent, {:controller_command, host, "gh", args})

      case args do
        ["pr", "list" | _] -> {:ok, {"[]", 0}}
        ["pr", "create" | _] -> {:ok, {"https://github.com/acme/repo/pull/1\n", 0}}
        ["pr", "view" | _] -> {:ok, {Jason.encode!(readback(ctx)), 0}}
      end
    end

    assert {:ok, _published} =
             EnginePublisher.publish(
               ctx.workspace,
               ctx.plan,
               "feat: change readme",
               body(),
               worker_host: "worker-a",
               command_runner: remote_runner,
               github_command_runner: controller_runner,
               repository_capture: fn workspace, _worker_host ->
                 SymphonyElixir.RepositoryFingerprint.capture(workspace, nil)
               end
             )

    assert_receive {:remote_command, "worker-a", "git", ["-C", _, "push", "origin", _]}
    assert_receive {:controller_command, nil, "gh", ["pr", "create" | _]}
    refute_receive {:remote_command, _, "gh", _}
  end

  test "requires at least one task commit", ctx do
    base = ctx.plan["repository"]["base_sha"]
    git(ctx.workspace, ["switch", "-q", "main"])
    git(ctx.workspace, ["switch", "-qc", "feature/sym-1-empty", base])

    plan = %{ctx.plan | "workflow" => "feature"}

    assert {:error, :publication_commit_required} =
             EnginePublisher.publish(
               ctx.workspace,
               plan,
               "feat: change readme",
               body()
             )
  end

  test "rejects multiple branch PRs and malformed readback", ctx do
    pulls = [
      %{"url" => "https://github.com/acme/repo/pull/1"},
      %{"url" => "https://github.com/acme/repo/pull/2"}
    ]

    assert {:error, {:multiple_pull_requests_for_branch, 2}} =
             EnginePublisher.publish(
               ctx.workspace,
               ctx.plan,
               "feat: change readme",
               body(),
               command_runner: publishing_runner(ctx, readback(ctx), pulls)
             )

    assert {:error, {:invalid_pull_request_readback, %{"url" => _}}} =
             EnginePublisher.publish(
               ctx.workspace,
               ctx.plan,
               "feat: change readme",
               body(),
               command_runner: publishing_runner(ctx, %{"url" => "https://github.com/acme/repo/pull/1"})
             )
  end

  defp body do
    """
    #### Context

    Needed.

    #### TL;DR

    *Change the readme.*

    #### Summary

    - Change the readme.

    #### Alternatives

    - None considered.

    #### Test Plan

    - [x] `mix test test/example_test.exs`
    """
  end

  defp readback(ctx) do
    %{
      "url" => "https://github.com/acme/repo/pull/1",
      "headRefOid" => ctx.head,
      "headRefName" => "feature/sym-1-test",
      "baseRefName" => "main",
      "state" => "OPEN",
      "isCrossRepository" => false
    }
  end

  defp publishing_runner(ctx, readback, pulls \\ [], recipient \\ nil) do
    fn workspace, _host, executable, args ->
      if recipient, do: send(recipient, {:command, executable, args})

      case {executable, args} do
        {"git", ["-C", ^workspace, "push", "origin", "feature/sym-1-test"]} ->
          {:ok, {"", 0}}

        {"gh", ["pr", "list" | _]} ->
          {:ok, {Jason.encode!(pulls), 0}}

        {"gh", ["pr", "create" | _]} ->
          {:ok, {"https://github.com/acme/repo/pull/1\n", 0}}

        {"gh", ["pr", "edit" | _]} ->
          {:ok, {"", 0}}

        {"gh", ["pr", "view" | _]} ->
          {:ok, {Jason.encode!(readback), 0}}

        {"git", ["-C", ^workspace | git_args]} ->
          {:ok, System.cmd("git", ["-C", ctx.workspace | git_args], stderr_to_stdout: true)}
      end
    end
  end

  defp git(workspace, args), do: System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true)
end
