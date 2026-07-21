defmodule SymphonyElixir.Codex.ThreadIdentity do
  @moduledoc """
  Owns the immutable Codex thread identity for one issue workspace.
  """

  alias SymphonyElixir.SSH

  @schema_version 1
  @artifact_dir ".symphony"
  @artifact_file "codex-thread.json"
  @max_thread_id_bytes 1_024
  @max_artifact_bytes 4_096

  @spec path(Path.t()) :: Path.t()
  def path(workspace) when is_binary(workspace) do
    Path.join([workspace, @artifact_dir, @artifact_file])
  end

  @spec read(Path.t()) :: :missing | {:ok, String.t()} | {:error, term()}
  def read(workspace) when is_binary(workspace), do: read(workspace, nil)

  @spec read(Path.t(), String.t() | nil) :: :missing | {:ok, String.t()} | {:error, term()}
  def read(workspace, nil) when is_binary(workspace) do
    artifact_path = path(workspace)

    case File.stat(artifact_path) do
      {:ok, %{size: size}} when size <= @max_artifact_bytes ->
        case File.read(artifact_path) do
          {:ok, payload} -> decode(payload)
          {:error, reason} -> {:error, {:thread_identity_read_failed, reason}}
        end

      {:ok, %{size: size}} ->
        {:error, {:thread_identity_too_large, size}}

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, {:thread_identity_read_failed, reason}}
    end
  end

  def read(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    command =
      "identity=#{shell_escape(path(workspace))}; " <>
        "if [ ! -f \"$identity\" ]; then exit 44; fi; " <>
        "size=$(wc -c < \"$identity\"); " <>
        ~s|if [ "$size" -gt #{@max_artifact_bytes} ]; then printf '%s' "$size"; exit 46; fi; | <>
        "cat \"$identity\""

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {payload, 0}} ->
        decode(payload)

      {:ok, {_output, 44}} ->
        :missing

      {:ok, {output, 46}} ->
        {:error, {:thread_identity_too_large, String.trim(output)}}

      {:ok, {output, status}} ->
        {:error, {:thread_identity_read_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, {:thread_identity_read_failed, worker_host, reason}}
    end
  end

  @spec pin(Path.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def pin(workspace, thread_id) when is_binary(workspace), do: pin(workspace, thread_id, nil)

  @spec pin(Path.t(), String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def pin(workspace, thread_id, worker_host) when is_binary(workspace) do
    with :ok <- validate_thread_id(thread_id) do
      case read(workspace, worker_host) do
        :missing ->
          write_new(workspace, thread_id, worker_host)

        {:ok, ^thread_id} ->
          {:ok, thread_id}

        {:ok, existing_thread_id} ->
          {:error, {:thread_identity_conflict, existing_thread_id, thread_id}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp decode(payload) do
    case Jason.decode(payload) do
      {:ok, %{"schema_version" => @schema_version, "thread_id" => thread_id}} ->
        case validate_thread_id(thread_id) do
          :ok -> {:ok, thread_id}
          {:error, reason} -> {:error, {:invalid_thread_identity, reason}}
        end

      {:ok, %{"schema_version" => version}} ->
        {:error, {:unsupported_thread_identity_version, version}}

      {:ok, _other} ->
        {:error, {:invalid_thread_identity, :invalid_shape}}

      {:error, reason} ->
        {:error, {:invalid_thread_identity, reason}}
    end
  end

  defp validate_thread_id(thread_id)
       when is_binary(thread_id) and byte_size(thread_id) <= @max_thread_id_bytes do
    if String.trim(thread_id) == "", do: {:error, :empty_thread_id}, else: :ok
  end

  defp validate_thread_id(thread_id) when is_binary(thread_id), do: {:error, :thread_id_too_long}
  defp validate_thread_id(_thread_id), do: {:error, :invalid_thread_id}

  defp write_new(workspace, thread_id, worker_host) do
    payload =
      Jason.encode!(%{"schema_version" => @schema_version, "thread_id" => thread_id}, pretty: true) <>
        "\n"

    case write_exclusive(workspace, payload, worker_host) do
      :ok -> read_and_validate(workspace, thread_id, worker_host)
      :exists -> read_and_validate(workspace, thread_id, worker_host)
      {:error, _reason} = error -> error
    end
  end

  defp read_and_validate(workspace, thread_id, worker_host) do
    case read(workspace, worker_host) do
      {:ok, ^thread_id} -> {:ok, thread_id}
      {:ok, existing_thread_id} -> {:error, {:thread_identity_conflict, existing_thread_id, thread_id}}
      other -> other
    end
  end

  defp write_exclusive(workspace, payload, nil) do
    artifact_path = path(workspace)
    artifact_dir = Path.dirname(artifact_path)
    temp_path = artifact_path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

    result =
      with :ok <- File.mkdir_p(artifact_dir),
           :ok <- File.write(temp_path, payload, [:write, :exclusive]),
           :ok <- File.chmod(temp_path, 0o600) do
        case File.ln(temp_path, artifact_path) do
          :ok -> :ok
          {:error, :eexist} -> :exists
          {:error, reason} -> {:error, {:thread_identity_write_failed, reason}}
        end
      else
        {:error, reason} -> {:error, {:thread_identity_write_failed, reason}}
      end

    File.rm(temp_path)
    result
  end

  defp write_exclusive(workspace, payload, worker_host) when is_binary(worker_host) do
    artifact_path = path(workspace)
    artifact_dir = Path.dirname(artifact_path)

    command =
      [
        "set -eu",
        "identity=#{shell_escape(artifact_path)}",
        "identity_dir=#{shell_escape(artifact_dir)}",
        "mkdir -p \"$identity_dir\"",
        "tmp=\"$identity.tmp.$$\"",
        "trap 'rm -f \"$tmp\"' EXIT",
        "umask 077",
        "printf '%s' #{shell_escape(payload)} > \"$tmp\"",
        "if ln \"$tmp\" \"$identity\" 2>/dev/null; then exit 0; else exit 45; fi"
      ]
      |> Enum.join("\n")

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {_output, 45}} -> :exists
      {:ok, {output, status}} -> {:error, {:thread_identity_write_failed, worker_host, status, output}}
      {:error, reason} -> {:error, {:thread_identity_write_failed, worker_host, reason}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
