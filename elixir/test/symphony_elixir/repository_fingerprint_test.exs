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

  test "invalidates when an untracked file changes in place", %{workspace: workspace} do
    path = Path.join(workspace, "new-source.ex")
    File.write!(path, "first version\n")
    assert {:ok, first} = RepositoryFingerprint.capture(workspace)

    File.write!(path, "second version\n")
    assert {:ok, second} = RepositoryFingerprint.capture(workspace)

    refute first.digest == second.digest
    refute first.untracked_digest == second.untracked_digest
  end

  test "ignores engine-owned symphony artifacts", %{workspace: workspace} do
    assert {:ok, first} = RepositoryFingerprint.capture(workspace)
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join(workspace, ".symphony/plan-candidate-1.json"), "{}")
    File.write!(Path.join(workspace, ".symphony/task-classification.json"), "{}")
    File.write!(Path.join(workspace, ".symphony/first-useful-edit"), "")
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

  test "captures independent repository observations in parallel", %{workspace: workspace} do
    parent = self()
    base_sha = String.duplicate("a", 40)

    runner = fn args ->
      send(parent, {:git_capture_started, self(), args})

      receive do
        :continue ->
          case args do
            ["config", "--get", "remote.origin.url"] -> {:ok, "git@github.com:acme/repo.git\n"}
            ["rev-parse", "HEAD"] -> {:ok, base_sha <> "\n"}
            _ -> {:ok, ""}
          end
      end
    end

    capture =
      Task.async(fn ->
        RepositoryFingerprint.capture(workspace, nil, git_runner: runner)
      end)

    started =
      for _index <- 1..6 do
        assert_receive {:git_capture_started, pid, args}, 1_000
        {pid, args}
      end

    Enum.each(started, fn {pid, _args} -> send(pid, :continue) end)

    assert {:ok, %{base_sha: ^base_sha, clean: true}} = Task.await(capture)
  end

  test "fails closed when the untracked input set exceeds its bound", %{workspace: workspace} do
    for index <- 1..257 do
      File.write!(Path.join(workspace, "untracked-#{index}.txt"), "#{index}\n")
    end

    assert {:error, {:too_many_untracked_files, 256}} =
             RepositoryFingerprint.capture(workspace)
  end

  test "fails closed when one untracked file exceeds its content bound", %{workspace: workspace} do
    File.write!(Path.join(workspace, "large.bin"), :binary.copy(<<0>>, 1_048_577))

    assert {:error, {:untracked_file_too_large, "large.bin", 1_048_576}} =
             RepositoryFingerprint.capture(workspace)
  end

  test "fails closed when aggregate untracked content exceeds its bound", %{workspace: workspace} do
    for index <- 1..5 do
      File.write!(
        Path.join(workspace, "large-#{index}.bin"),
        :binary.copy(<<index>>, 1_048_576)
      )
    end

    assert {:error, {:untracked_content_too_large, 4_194_304}} =
             RepositoryFingerprint.capture(workspace)
  end

  test "fails closed when a repository observation exceeds its subprocess timeout", %{
    workspace: workspace
  } do
    runner = fn _args ->
      Process.sleep(50)
      {:ok, ""}
    end

    assert {:error, {:git_command_timeout, _command}} =
             RepositoryFingerprint.capture(workspace, nil,
               git_runner: runner,
               command_timeout_ms: 5
             )
  end

  test "invalidates for instructions, workflow, manifests, lockfiles, and toolchain configuration", %{
    workspace: workspace
  } do
    assert {:ok, initial} = RepositoryFingerprint.capture(workspace)

    final =
      Enum.reduce(
        ["AGENTS.md", "workflow.md", "mix.exs", "mix.lock", "mise.toml"],
        initial,
        fn path, previous ->
          File.write!(Path.join(workspace, path), "#{path}\n")
          assert {:ok, current} = RepositoryFingerprint.capture(workspace)
          refute current.digest == previous.digest
          current
        end
      )

    refute final.digest == initial.digest
  end

  test "changed paths preserve spaces and newlines", %{workspace: workspace} do
    {base_sha, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])
    spaced = "path with spaces.txt"
    newline = "path\nwith-newline.txt"
    File.write!(Path.join(workspace, spaced), "spaced\n")
    File.write!(Path.join(workspace, newline), "newline\n")

    assert {:ok, paths} = RepositoryFingerprint.changed_paths(workspace, String.trim(base_sha))
    assert paths == Enum.sort([newline, spaced])
  end

  test "changed paths include both sides of a dirty rename", %{workspace: workspace} do
    {base_sha, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])
    renamed = "renamed tracked.txt"
    System.cmd("git", ["-C", workspace, "mv", "tracked.txt", renamed])

    assert {:ok, paths} = RepositoryFingerprint.changed_paths(workspace, String.trim(base_sha))
    assert paths == Enum.sort(["tracked.txt", renamed])
  end

  test "changed paths include both sides of a committed rename", %{workspace: workspace} do
    {base_sha, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])
    renamed = "committed rename.txt"
    System.cmd("git", ["-C", workspace, "mv", "tracked.txt", renamed])
    System.cmd("git", ["-C", workspace, "commit", "-qm", "chore: rename tracked file"])

    assert {:ok, paths} = RepositoryFingerprint.changed_paths(workspace, String.trim(base_sha))
    assert paths == Enum.sort(["tracked.txt", renamed])
  end
end
