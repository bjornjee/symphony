defmodule SymphonyElixir.ExecutionManifest do
  @moduledoc """
  Pins the approved Linear plan revision to a workspace without overwriting drift.
  """

  alias SymphonyElixir.Linear.{Issue, TaskContract}
  alias SymphonyElixir.SSH

  @schema_version 1
  @manifest_dir ".symphony"
  @manifest_file "execution-manifest.json"

  @spec path(Path.t()) :: Path.t()
  def path(workspace) when is_binary(workspace) do
    Path.join([workspace, @manifest_dir, @manifest_file])
  end

  @spec pin(Path.t(), Issue.t(), TaskContract.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def pin(workspace, %Issue{} = issue, %TaskContract{} = contract, worker_host \\ nil)
      when is_binary(workspace) do
    with :ok <- validate_issue_identity(issue),
         {:ok, existing} <- read(workspace, worker_host) do
      validate_existing(existing, issue, contract)
    else
      :missing -> write_new(workspace, issue, contract, worker_host)
      {:error, _reason} = error -> error
    end
  end

  defp validate_issue_identity(%Issue{id: id, identifier: identifier})
       when is_binary(id) and id != "" and is_binary(identifier) and identifier != "",
       do: :ok

  defp validate_issue_identity(_issue), do: {:error, :missing_manifest_issue_identity}

  defp read(workspace, nil) do
    case File.read(path(workspace)) do
      {:ok, payload} -> decode(payload)
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, {:execution_manifest_read_failed, reason}}
    end
  end

  defp read(workspace, worker_host) when is_binary(worker_host) do
    command =
      "manifest=#{shell_escape(path(workspace))}; " <>
        "if [ -f \"$manifest\" ]; then cat \"$manifest\"; else exit 44; fi"

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {payload, 0}} -> decode(payload)
      {:ok, {_output, 44}} -> :missing
      {:ok, {output, status}} -> {:error, {:execution_manifest_read_failed, worker_host, status, output}}
      {:error, reason} -> {:error, {:execution_manifest_read_failed, worker_host, reason}}
    end
  end

  defp decode(payload) do
    case Jason.decode(payload) do
      {:ok, manifest} when is_map(manifest) -> {:ok, manifest}
      {:ok, _other} -> {:error, {:invalid_execution_manifest, :not_a_map}}
      {:error, reason} -> {:error, {:invalid_execution_manifest, reason}}
    end
  end

  defp validate_existing(manifest, issue, contract) do
    cond do
      manifest["schema_version"] != @schema_version ->
        {:error, {:unsupported_execution_manifest_version, manifest["schema_version"]}}

      manifest["issue_id"] != issue.id ->
        {:error, {:manifest_issue_mismatch, manifest["issue_id"], issue.id}}

      manifest["issue_identifier"] != issue.identifier ->
        {:error, {:manifest_identifier_mismatch, manifest["issue_identifier"], issue.identifier}}

      manifest["plan_digest"] != contract.digest ->
        {:error, {:plan_drift, manifest["plan_digest"], contract.digest}}

      true ->
        {:ok, manifest}
    end
  end

  defp write_new(workspace, issue, contract, worker_host) do
    manifest = %{
      "schema_version" => @schema_version,
      "task_contract_version" => contract.version,
      "issue_id" => issue.id,
      "issue_identifier" => issue.identifier,
      "plan_digest" => contract.digest,
      "acceptance_criteria" =>
        Enum.map(contract.acceptance_criteria, fn criterion ->
          %{"id" => criterion.id, "text" => criterion.text}
        end),
      "source_updated_at" => format_datetime(issue.updated_at),
      "pinned_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    payload = Jason.encode!(manifest, pretty: true) <> "\n"

    with :ok <- write_atomic(workspace, payload, worker_host),
         {:ok, persisted} <- read(workspace, worker_host) do
      validate_existing(persisted, issue, contract)
    end
  end

  defp write_atomic(workspace, payload, nil) do
    manifest_path = path(workspace)
    manifest_dir = Path.dirname(manifest_path)
    temp_path = manifest_path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

    with :ok <- File.mkdir_p(manifest_dir),
         :ok <- File.write(temp_path, payload, [:write, :exclusive]),
         :ok <- File.rename(temp_path, manifest_path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temp_path)
        {:error, {:execution_manifest_write_failed, reason}}
    end
  end

  defp write_atomic(workspace, payload, worker_host) when is_binary(worker_host) do
    manifest_path = path(workspace)
    manifest_dir = Path.dirname(manifest_path)

    command =
      [
        "set -eu",
        "manifest=#{shell_escape(manifest_path)}",
        "manifest_dir=#{shell_escape(manifest_dir)}",
        "mkdir -p \"$manifest_dir\"",
        "tmp=\"$manifest.tmp.$$\"",
        "trap 'rm -f \"$tmp\"' EXIT",
        "umask 077",
        "printf '%s' #{shell_escape(payload)} > \"$tmp\"",
        "mv \"$tmp\" \"$manifest\"",
        "trap - EXIT"
      ]
      |> Enum.join("\n")

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:execution_manifest_write_failed, worker_host, status, output}}
      {:error, reason} -> {:error, {:execution_manifest_write_failed, worker_host, reason}}
    end
  end

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(_datetime), do: nil

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
