defmodule SymphonyElixir.RepositoryFingerprintTest do
  use ExUnit.Case

  alias SymphonyElixir.RepositoryFingerprint

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-repository-fingerprint-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(workspace)
    System.cmd("git", ["init", "-q", workspace])
    System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", workspace, "config", "user.name", "Test"])
    System.cmd("git", ["-C", workspace, "remote", "add", "origin", "git@github.com:acme/repo.git"])
    File.write!(Path.join(workspace, "tracked.txt"), "one\n")
    System.cmd("git", ["-C", workspace, "add", "tracked.txt"])
    System.cmd("git", ["-C", workspace, "commit", "-qm", "initial"])
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  test "captures origin, base revision, and tracked/untracked state", %{workspace: workspace} do
    assert {:ok, first} = RepositoryFingerprint.capture(workspace)
    assert first.origin == "git@github.com:acme/repo.git"
    assert byte_size(first.base_sha) == 40
    assert byte_size(first.digest) == 64

    File.write!(Path.join(workspace, "untracked.txt"), "new\n")
    assert {:ok, second} = RepositoryFingerprint.capture(workspace)
    refute first.digest == second.digest
  end

  test "ignores engine-owned symphony artifacts", %{workspace: workspace} do
    assert {:ok, first} = RepositoryFingerprint.capture(workspace)
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join(workspace, ".symphony/plan-candidate-1.json"), "{}")
    assert {:ok, second} = RepositoryFingerprint.capture(workspace)
    assert first.digest == second.digest
  end

  test "captures the same repository identity through the SSH boundary", %{workspace: workspace} do
    fake_bin = Path.join(workspace, "fake-bin")
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

    assert {:ok, local} = RepositoryFingerprint.capture(workspace)
    assert {:ok, remote} = RepositoryFingerprint.capture(workspace, "worker-a")
    assert remote == local
    assert {:ok, local.base_sha} == RepositoryFingerprint.head(workspace, "worker-a")
  end
end
