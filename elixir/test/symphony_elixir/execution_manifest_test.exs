defmodule SymphonyElixir.ExecutionManifestTest do
  use ExUnit.Case

  import SymphonyElixir.TaskContractFixtures
  alias SymphonyElixir.ExecutionManifest
  alias SymphonyElixir.Linear.TaskContract

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-execution-manifest-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  test "pins an atomic manifest with issue identity and provenance", %{workspace: workspace} do
    task = issue()
    assert {:ok, contract} = TaskContract.from_issue(task)
    assert {:ok, manifest} = ExecutionManifest.pin(workspace, task, contract)

    assert manifest["schema_version"] == 1
    assert manifest["issue_id"] == task.id
    assert manifest["issue_identifier"] == task.identifier
    assert manifest["plan_digest"] == contract.digest

    assert manifest["acceptance_criteria"] ==
             Enum.map(contract.acceptance_criteria, fn criterion ->
               %{"id" => criterion.id, "text" => criterion.text}
             end)

    assert manifest["source_updated_at"] == "2026-07-21T03:00:00Z"
    assert File.regular?(ExecutionManifest.path(workspace))
    refute File.exists?(ExecutionManifest.path(workspace) <> ".tmp")
  end

  test "reuses the manifest for the same issue revision", %{workspace: workspace} do
    task = issue()
    assert {:ok, contract} = TaskContract.from_issue(task)
    assert {:ok, first} = ExecutionManifest.pin(workspace, task, contract)
    assert {:ok, second} = ExecutionManifest.pin(workspace, task, contract)
    assert first == second
  end

  test "rejects plan drift without overwriting the pinned revision", %{workspace: workspace} do
    task = issue()
    assert {:ok, contract} = TaskContract.from_issue(task)
    assert {:ok, pinned} = ExecutionManifest.pin(workspace, task, contract)
    assert {:ok, changed} = TaskContract.from_issue(%{task | title: "Changed after approval"})

    assert {:error, {:plan_drift, expected, actual}} =
             ExecutionManifest.pin(workspace, task, changed)

    assert expected == pinned["plan_digest"]
    assert actual == changed.digest
    assert Jason.decode!(File.read!(ExecutionManifest.path(workspace))) == pinned
  end

  test "rejects a manifest belonging to another issue", %{workspace: workspace} do
    task = issue()
    assert {:ok, contract} = TaskContract.from_issue(task)
    assert {:ok, _manifest} = ExecutionManifest.pin(workspace, task, contract)

    other = issue(%{id: "issue-2", identifier: "PIN-99"})
    assert {:ok, other_contract} = TaskContract.from_issue(other)

    assert {:error, {:manifest_issue_mismatch, "issue-1", "issue-2"}} =
             ExecutionManifest.pin(workspace, other, other_contract)
  end

  test "rejects malformed manifest JSON", %{workspace: workspace} do
    File.mkdir_p!(Path.dirname(ExecutionManifest.path(workspace)))
    File.write!(ExecutionManifest.path(workspace), "not-json")
    task = issue()
    assert {:ok, contract} = TaskContract.from_issue(task)

    assert {:error, {:invalid_execution_manifest, _reason}} =
             ExecutionManifest.pin(workspace, task, contract)
  end

  test "rejects a non-object manifest", %{workspace: workspace} do
    File.mkdir_p!(Path.dirname(ExecutionManifest.path(workspace)))
    File.write!(ExecutionManifest.path(workspace), "[]")
    task = issue()
    assert {:ok, contract} = TaskContract.from_issue(task)

    assert {:error, {:invalid_execution_manifest, :not_a_map}} =
             ExecutionManifest.pin(workspace, task, contract)
  end

  test "rejects an unsupported manifest schema", %{workspace: workspace} do
    task = issue()
    assert {:ok, contract} = TaskContract.from_issue(task)
    assert {:ok, manifest} = ExecutionManifest.pin(workspace, task, contract)
    File.write!(ExecutionManifest.path(workspace), Jason.encode!(%{manifest | "schema_version" => 99}))

    assert {:error, {:unsupported_execution_manifest_version, 99}} =
             ExecutionManifest.pin(workspace, task, contract)
  end

  test "rejects a mismatched issue identifier", %{workspace: workspace} do
    task = issue()
    assert {:ok, contract} = TaskContract.from_issue(task)
    assert {:ok, _manifest} = ExecutionManifest.pin(workspace, task, contract)
    renamed = %{task | identifier: "PIN-RENAMED"}

    assert {:error, {:manifest_identifier_mismatch, "PIN-14", "PIN-RENAMED"}} =
             ExecutionManifest.pin(workspace, renamed, contract)
  end

  test "requires stable issue identity", %{workspace: workspace} do
    task = issue(%{id: nil})
    assert {:ok, contract} = TaskContract.from_issue(task)

    assert {:error, :missing_manifest_issue_identity} =
             ExecutionManifest.pin(workspace, task, contract)
  end

  test "updatedAt changes do not replace the pinned provenance", %{workspace: workspace} do
    task = issue()
    assert {:ok, contract} = TaskContract.from_issue(task)
    assert {:ok, first} = ExecutionManifest.pin(workspace, task, contract)
    refreshed = %{task | updated_at: ~U[2026-07-21 04:00:00Z]}
    assert {:ok, refreshed_contract} = TaskContract.from_issue(refreshed)
    assert {:ok, second} = ExecutionManifest.pin(workspace, refreshed, refreshed_contract)

    assert second == first
    assert second["source_updated_at"] == "2026-07-21T03:00:00Z"
  end

  test "pins and reuses a manifest through the SSH boundary", %{workspace: workspace} do
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

    task = issue(%{identifier: "PIN-'14"})
    assert {:ok, contract} = TaskContract.from_issue(task)
    assert {:ok, first} = ExecutionManifest.pin(workspace, task, contract, "worker-a")
    assert {:ok, second} = ExecutionManifest.pin(workspace, task, contract, "worker-a")

    assert second == first
    assert second["issue_identifier"] == "PIN-'14"
  end

  test "does not overwrite a revision pinned between the remote read and write", %{workspace: workspace} do
    original_path = System.get_env("PATH")
    original_competing_manifest = System.get_env("COMPETING_MANIFEST")
    original_target_manifest = System.get_env("TARGET_MANIFEST")
    fake_bin = Path.join(workspace, "fake-bin")
    fake_ssh = Path.join(fake_bin, "ssh")
    competing_workspace = Path.join(workspace, "competing")
    File.mkdir_p!(fake_bin)
    File.mkdir_p!(competing_workspace)

    task = issue()
    assert {:ok, contract} = TaskContract.from_issue(task)
    changed_task = %{task | title: "Competing approved revision"}
    assert {:ok, changed_contract} = TaskContract.from_issue(changed_task)
    assert {:ok, _manifest} = ExecutionManifest.pin(competing_workspace, changed_task, changed_contract)

    File.write!(fake_ssh, """
    #!/bin/sh
    for arg in "$@"; do remote_command="$arg"; done
    case "$remote_command" in
      *"tmp="*)
        mkdir -p "$(dirname "$TARGET_MANIFEST")"
        cp "$COMPETING_MANIFEST" "$TARGET_MANIFEST"
        ;;
    esac
    eval "$remote_command"
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin <> ":" <> (original_path || ""))
    System.put_env("COMPETING_MANIFEST", ExecutionManifest.path(competing_workspace))
    System.put_env("TARGET_MANIFEST", ExecutionManifest.path(workspace))

    on_exit(fn ->
      restore_env("PATH", original_path)
      restore_env("COMPETING_MANIFEST", original_competing_manifest)
      restore_env("TARGET_MANIFEST", original_target_manifest)
    end)

    assert {:error, {:plan_drift, expected, actual}} =
             ExecutionManifest.pin(workspace, task, contract, "worker-a")

    assert expected == changed_contract.digest
    assert actual == contract.digest
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
