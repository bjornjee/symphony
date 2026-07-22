defmodule SymphonyElixir.RepositoryReviewSnapshotTest do
  use ExUnit.Case

  alias SymphonyElixir.RepositoryReviewSnapshot

  setup do
    root = Path.join(System.tmp_dir!(), "review-snapshot-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(root)
    git(root, ["init", "-q", "-b", "main"])
    git(root, ["config", "user.email", "test@example.com"])
    git(root, ["config", "user.name", "Test"])
    git(root, ["remote", "add", "origin", "git@github.com:acme/repo.git"])
    File.write!(Path.join(root, "README.md"), "base\n")
    git(root, ["add", "README.md"])
    git(root, ["commit", "-qm", "chore: base"])
    {base, 0} = git(root, ["rev-parse", "HEAD"])
    File.write!(Path.join(root, "README.md"), "changed\n")
    git(root, ["commit", "-qam", "chore: change"])
    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: root, base: String.trim(base)}
  end

  test "captures a bounded local and SSH base-to-head snapshot", ctx do
    assert {:ok, local} = RepositoryReviewSnapshot.capture(ctx.workspace, ctx.base)
    assert local.changed_paths == ["README.md"]
    assert local.diff =~ "+changed"

    fake_bin =
      Path.join(System.tmp_dir!(), "review-snapshot-ssh-#{System.os_time(:nanosecond)}")

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
      File.rm_rf(fake_bin)
    end)

    assert {:ok, remote} =
             RepositoryReviewSnapshot.capture(ctx.workspace, ctx.base, "worker-a")

    assert remote.changed_paths == local.changed_paths
    assert remote.diff == local.diff
  end

  test "fails closed when the pinned base cannot be read", ctx do
    assert {:error, {:git_failed, _, _, _}} =
             RepositoryReviewSnapshot.capture(ctx.workspace, String.duplicate("0", 40))
  end

  defp git(workspace, args),
    do: System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true)
end
