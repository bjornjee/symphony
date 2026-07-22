defmodule SymphonyElixir.WorkspaceArtifactTest do
  use ExUnit.Case

  alias SymphonyElixir.WorkspaceArtifact

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-artifact-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace, path: Path.join(workspace, "artifact.json")}
  end

  test "reads no more than the configured byte limit", %{path: path} do
    File.write!(path, "12345")

    assert {:error, {:artifact_too_large, 4}} = WorkspaceArtifact.read(path, 4)
  end

  test "reads an empty regular file", %{path: path} do
    File.write!(path, "")
    assert {:ok, ""} = WorkspaceArtifact.read(path, 1)
  end

  test "rejects symlinks before reading their target", %{workspace: workspace, path: path} do
    target = Path.join(workspace, "target.json")
    File.write!(target, "{}")
    File.ln_s!(target, path)

    assert {:error, {:invalid_artifact_type, :symlink}} = WorkspaceArtifact.read(path, 4)
  end

  test "rejects a fifo without opening or blocking on it", %{path: path} do
    assert {_, 0} = System.cmd("mkfifo", [path])

    assert {:error, {:invalid_artifact_type, :other}} = WorkspaceArtifact.read(path, 4)
  end

  test "rejects a symlinked artifact directory", %{workspace: workspace} do
    target = Path.join(workspace, "outside")
    artifact_dir = Path.join(workspace, "linked-artifacts")
    path = Path.join(artifact_dir, "artifact.json")
    File.mkdir_p!(target)
    File.write!(Path.join(target, "artifact.json"), "{}")
    File.ln_s!(target, artifact_dir)

    assert {:error, {:invalid_artifact_directory_type, :symlink}} =
             WorkspaceArtifact.read(path, 4)

    assert {:error, {:invalid_artifact_directory_type, :symlink}} =
             WorkspaceArtifact.create_exclusive(path, "replacement")

    assert File.read!(Path.join(target, "artifact.json")) == "{}"
  end

  test "creates an artifact once without replacing the winner", %{path: path} do
    assert :ok = WorkspaceArtifact.create_exclusive(path, "first")
    assert :exists = WorkspaceArtifact.create_exclusive(path, "second")
    assert File.read!(path) == "first"
  end

  test "remote artifact paths enforce the same exclusive and bounded semantics", %{
    workspace: workspace,
    path: path
  } do
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

    assert :ok = WorkspaceArtifact.create_exclusive(path, "first", "worker-a")
    assert :exists = WorkspaceArtifact.create_exclusive(path, "second", "worker-a")
    assert {:ok, "first"} = WorkspaceArtifact.read(path, 5, "worker-a")
    assert {:error, {:artifact_too_large, 4}} = WorkspaceArtifact.read(path, 4, "worker-a")

    target = Path.join(workspace, "remote-target.json")
    symlink = Path.join(workspace, "remote-symlink.json")
    fifo = Path.join(workspace, "remote-fifo")
    File.write!(target, "{}")
    File.ln_s!(target, symlink)
    assert {_, 0} = System.cmd("mkfifo", [fifo])

    assert {:error, {:invalid_artifact_type, :symlink}} =
             WorkspaceArtifact.read(symlink, 4, "worker-a")

    assert {:error, {:invalid_artifact_type, :other}} =
             WorkspaceArtifact.read(fifo, 4, "worker-a")

    linked_dir = Path.join(workspace, "remote-linked-artifacts")
    File.ln_s!(Path.dirname(target), linked_dir)

    assert {:error, {:invalid_artifact_directory_type, :symlink}} =
             WorkspaceArtifact.read(Path.join(linked_dir, "remote-target.json"), 4, "worker-a")

    assert {:error, {:invalid_artifact_directory_type, :symlink}} =
             WorkspaceArtifact.create_exclusive(Path.join(linked_dir, "new.json"), "x", "worker-a")

    File.write!(fake_ssh, "#!/bin/sh\nprintf 'remote failure'\nexit 49\n")

    assert {:error, {:remote_command_failed, 49, "remote failure"}} =
             WorkspaceArtifact.read(path, 5, "worker-a")

    assert {:error, {:remote_command_failed, 49, "remote failure"}} =
             WorkspaceArtifact.create_exclusive(Path.join(workspace, "failed.json"), "x", "worker-a")
  end
end
