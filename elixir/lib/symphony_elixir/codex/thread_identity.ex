defmodule SymphonyElixir.Codex.ThreadIdentity do
  @moduledoc """
  Owns the immutable Codex thread identity for one issue workspace.
  """

  alias SymphonyElixir.WorkspaceArtifact

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
    case WorkspaceArtifact.read(path(workspace), @max_artifact_bytes) do
      {:ok, payload} -> decode(payload)
      :missing -> :missing
      {:error, {:artifact_too_large, max_bytes}} -> {:error, {:thread_identity_too_large, max_bytes + 1}}
      {:error, reason} -> {:error, {:thread_identity_read_failed, reason}}
    end
  end

  def read(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    case WorkspaceArtifact.read(path(workspace), @max_artifact_bytes, worker_host) do
      {:ok, payload} ->
        decode(payload)

      :missing ->
        :missing

      {:error, {:artifact_too_large, max_bytes}} ->
        {:error, {:thread_identity_too_large, Integer.to_string(max_bytes + 1)}}

      {:error, {:remote_command_failed, status, output}} ->
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
    case WorkspaceArtifact.create_exclusive(path(workspace), payload) do
      result when result in [:ok, :exists] -> result
      {:error, reason} -> {:error, {:thread_identity_write_failed, reason}}
    end
  end

  defp write_exclusive(workspace, payload, worker_host) when is_binary(worker_host) do
    case WorkspaceArtifact.create_exclusive(path(workspace), payload, worker_host) do
      result when result in [:ok, :exists] ->
        result

      {:error, {:remote_command_failed, status, output}} ->
        {:error, {:thread_identity_write_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, {:thread_identity_write_failed, worker_host, reason}}
    end
  end
end
