defmodule SymphonyElixir.CodexThreadIdentityTest do
  use ExUnit.Case

  alias SymphonyElixir.Codex.ThreadIdentity

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-codex-thread-identity-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  test "pins and reuses one canonical thread id", %{workspace: workspace} do
    assert :missing = ThreadIdentity.read(workspace)
    assert {:ok, "thread-1"} = ThreadIdentity.pin(workspace, "thread-1")
    assert {:ok, "thread-1"} = ThreadIdentity.pin(workspace, "thread-1")
    assert {:ok, "thread-1"} = ThreadIdentity.read(workspace)

    assert %{"schema_version" => 1, "thread_id" => "thread-1"} =
             ThreadIdentity.path(workspace) |> File.read!() |> Jason.decode!()
  end

  test "rejects a different thread id without overwriting", %{workspace: workspace} do
    assert {:ok, "thread-1"} = ThreadIdentity.pin(workspace, "thread-1")

    assert {:error, {:thread_identity_conflict, "thread-1", "thread-2"}} =
             ThreadIdentity.pin(workspace, "thread-2")

    assert {:ok, "thread-1"} = ThreadIdentity.read(workspace)
  end

  test "rejects malformed and unsupported artifacts", %{workspace: workspace} do
    File.mkdir_p!(Path.dirname(ThreadIdentity.path(workspace)))
    File.write!(ThreadIdentity.path(workspace), "not-json")

    assert {:error, {:invalid_thread_identity, _reason}} = ThreadIdentity.read(workspace)

    File.write!(
      ThreadIdentity.path(workspace),
      Jason.encode!(%{"schema_version" => 99, "thread_id" => "thread-1"})
    )

    assert {:error, {:unsupported_thread_identity_version, 99}} = ThreadIdentity.read(workspace)
  end

  test "rejects oversized artifacts without decoding them", %{workspace: workspace} do
    File.mkdir_p!(Path.dirname(ThreadIdentity.path(workspace)))
    File.write!(ThreadIdentity.path(workspace), String.duplicate("x", 4_097))

    assert {:error, {:thread_identity_too_large, 4_097}} = ThreadIdentity.read(workspace)
  end

  test "rejects invalid thread ids and artifact shapes", %{workspace: workspace} do
    assert {:error, :empty_thread_id} = ThreadIdentity.pin(workspace, "  ")

    assert {:error, :thread_id_too_long} =
             ThreadIdentity.pin(workspace, String.duplicate("x", 1_025))

    assert {:error, :invalid_thread_id} = ThreadIdentity.pin(workspace, nil)

    File.mkdir_p!(Path.dirname(ThreadIdentity.path(workspace)))
    File.write!(ThreadIdentity.path(workspace), Jason.encode!(["thread-1"]))

    assert {:error, {:invalid_thread_identity, :invalid_shape}} = ThreadIdentity.read(workspace)
  end

  test "pins and reuses the thread id through the SSH boundary", %{workspace: workspace} do
    original_path = System.get_env("PATH")
    fake_bin = Path.join(workspace, "fake-bin")
    fake_ssh = Path.join(fake_bin, "ssh")
    File.mkdir_p!(fake_bin)

    File.write!(fake_ssh, """
    #!/bin/sh
    for arg in "$@"; do remote_command="$arg"; done
    eval "$remote_command"
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin <> ":" <> (original_path || ""))
    on_exit(fn -> restore_path(original_path) end)

    assert {:ok, "thread-'remote"} =
             ThreadIdentity.pin(workspace, "thread-'remote", "worker-a")

    assert {:ok, "thread-'remote"} = ThreadIdentity.read(workspace, "worker-a")

    assert {:error, {:thread_identity_conflict, "thread-'remote", "thread-other"}} =
             ThreadIdentity.pin(workspace, "thread-other", "worker-a")

    File.write!(ThreadIdentity.path(workspace), String.duplicate("x", 4_097))

    assert {:error, {:thread_identity_too_large, "4097"}} =
             ThreadIdentity.read(workspace, "worker-a")
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)
end
