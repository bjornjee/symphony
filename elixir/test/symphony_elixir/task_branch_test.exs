defmodule SymphonyElixir.TaskBranchTest do
  use ExUnit.Case

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TaskBranch

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-task-branch-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(workspace)
    System.cmd("git", ["init", "-q", workspace])
    System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", workspace, "config", "user.name", "Test"])
    File.write!(Path.join(workspace, "README.md"), "initial\n")
    System.cmd("git", ["-C", workspace, "add", "README.md"])
    System.cmd("git", ["-C", workspace, "commit", "-qm", "initial"])
    {base_sha, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])
    on_exit(fn -> File.rm_rf(workspace) end)

    issue = %Issue{id: "issue-1", identifier: "SYM-42", title: "Repair handoff validation"}
    %{workspace: workspace, issue: issue, base_sha: String.trim(base_sha)}
  end

  test "creates and then resumes one task branch from the pinned base", ctx do
    assert {:ok, branch} = TaskBranch.ensure(ctx.workspace, ctx.issue, "fix", ctx.base_sha)
    assert branch == "fix/sym-42-repair-handoff-validation"

    {current, 0} = System.cmd("git", ["-C", ctx.workspace, "branch", "--show-current"])
    assert String.trim(current) == branch

    assert {:ok, ^branch} = TaskBranch.ensure(ctx.workspace, ctx.issue, "fix", ctx.base_sha)
  end

  test "rejects an unrelated branch that has advanced beyond the pinned base", ctx do
    System.cmd("git", ["-C", ctx.workspace, "switch", "-qc", "unrelated"])
    File.write!(Path.join(ctx.workspace, "README.md"), "advanced\n")
    System.cmd("git", ["-C", ctx.workspace, "commit", "-qam", "advance"])

    assert {:error, {:unexpected_task_branch, "unrelated"}} =
             TaskBranch.ensure(ctx.workspace, ctx.issue, "fix", ctx.base_sha)
  end

  test "creates and resumes the same branch through the SSH boundary", ctx do
    fake_bin = Path.join(ctx.workspace, "fake-bin")
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

    assert {:ok, branch} =
             TaskBranch.ensure(ctx.workspace, ctx.issue, "fix", ctx.base_sha, "worker-a")

    assert {:ok, ^branch} =
             TaskBranch.ensure(ctx.workspace, ctx.issue, "fix", ctx.base_sha, "worker-a")
  end

  test "switches to an existing task branch from the pinned base", ctx do
    expected = "fix/sym-42-repair-handoff-validation"
    System.cmd("git", ["-C", ctx.workspace, "branch", expected, ctx.base_sha])

    assert {:ok, ^expected} = TaskBranch.ensure(ctx.workspace, ctx.issue, "fix", ctx.base_sha)
  end

  test "rejects an existing task branch that does not descend from the pinned base", ctx do
    expected = "fix/sym-42-repair-handoff-validation"
    {tree, 0} = System.cmd("git", ["-C", ctx.workspace, "rev-parse", "HEAD^{tree}"])

    {unrelated_commit, 0} =
      System.cmd("git", ["-C", ctx.workspace, "commit-tree", "-m", "unrelated root", String.trim(tree)])

    System.cmd("git", ["-C", ctx.workspace, "branch", expected, String.trim(unrelated_commit)])

    assert {:error, {:task_branch_base_mismatch, ^expected, _base, _status}} =
             TaskBranch.ensure(ctx.workspace, ctx.issue, "fix", ctx.base_sha)

    {current, 0} = System.cmd("git", ["-C", ctx.workspace, "branch", "--show-current"])
    refute String.trim(current) == expected
  end

  test "rejects a task branch that does not descend from the pinned base", ctx do
    assert {:ok, _branch} = TaskBranch.ensure(ctx.workspace, ctx.issue, "fix", ctx.base_sha)

    assert {:error, {:task_branch_base_mismatch, _branch, _base, _status}} =
             TaskBranch.ensure(
               ctx.workspace,
               ctx.issue,
               "fix",
               String.duplicate("0", 40)
             )
  end
end
