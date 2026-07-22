defmodule SymphonyElixir.WorkspaceArtifact do
  @moduledoc false

  alias SymphonyElixir.SSH

  @type worker_host :: String.t() | nil

  @spec read(Path.t(), pos_integer()) :: :missing | {:ok, binary()} | {:error, term()}
  def read(path, max_bytes) when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    read(path, max_bytes, nil)
  end

  @spec read(Path.t(), pos_integer(), worker_host()) ::
          :missing | {:ok, binary()} | {:error, term()}
  def read(path, max_bytes, nil)
      when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    # ponytail: lstat then bounded open; use descriptor-level O_NOFOLLOW if concurrent path
    # replacement enters the threat model.
    with :ok <- validate_local_artifact_directory(path, true) do
      case File.lstat(path) do
        {:ok, %{type: :regular}} -> read_local_file(path, max_bytes)
        {:ok, %{type: type}} -> {:error, {:invalid_artifact_type, type}}
        {:error, :enoent} -> :missing
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def read(path, max_bytes, worker_host)
      when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 and is_binary(worker_host) do
    command =
      [
        "artifact=#{shell_escape(path)}",
        "artifact_dir=#{shell_escape(Path.dirname(path))}",
        "if [ -L \"$artifact_dir\" ]; then exit 47; fi",
        "if [ -e \"$artifact_dir\" ] && [ ! -d \"$artifact_dir\" ]; then exit 48; fi",
        "if [ -L \"$artifact\" ]; then exit 45; fi",
        "if [ ! -e \"$artifact\" ]; then exit 44; fi",
        "if [ ! -f \"$artifact\" ]; then exit 46; fi",
        "head -c #{max_bytes + 1} \"$artifact\""
      ]
      |> Enum.join("\n")

    worker_host
    |> SSH.run(command, stderr_to_stdout: true)
    |> remote_read_result(max_bytes)
  end

  @spec create_exclusive(Path.t(), iodata()) :: :ok | :exists | {:error, term()}
  def create_exclusive(path, payload) when is_binary(path) do
    create_exclusive(path, payload, nil)
  end

  @spec create_exclusive(Path.t(), iodata(), worker_host()) ::
          :ok | :exists | {:error, term()}
  def create_exclusive(path, payload, nil) when is_binary(path) do
    artifact_dir = Path.dirname(path)
    temp_path = path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

    result =
      with :ok <- File.mkdir_p(artifact_dir),
           :ok <- validate_local_artifact_directory(path, false),
           :ok <- File.write(temp_path, payload, [:write, :exclusive]),
           :ok <- File.chmod(temp_path, 0o600) do
        case File.ln(temp_path, path) do
          :ok -> :ok
          {:error, :eexist} -> :exists
          {:error, reason} -> {:error, reason}
        end
      end

    File.rm(temp_path)
    result
  end

  def create_exclusive(path, payload, worker_host)
      when is_binary(path) and is_binary(worker_host) do
    artifact_dir = Path.dirname(path)

    command =
      [
        "set -eu",
        "artifact=#{shell_escape(path)}",
        "artifact_dir=#{shell_escape(artifact_dir)}",
        "if [ -L \"$artifact_dir\" ]; then exit 47; fi",
        "mkdir -p \"$artifact_dir\"",
        "if [ ! -d \"$artifact_dir\" ]; then exit 48; fi",
        "tmp=\"$artifact.tmp.$$\"",
        "trap 'rm -f \"$tmp\"' EXIT",
        "umask 077",
        "printf '%s' #{shell_escape(IO.iodata_to_binary(payload))} > \"$tmp\"",
        "if ln \"$tmp\" \"$artifact\" 2>/dev/null; then exit 0; fi",
        "if [ -e \"$artifact\" ] || [ -L \"$artifact\" ]; then exit 45; fi",
        "exit 46"
      ]
      |> Enum.join("\n")

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {_output, 45}} -> :exists
      {:ok, {_output, 47}} -> {:error, {:invalid_artifact_directory_type, :symlink}}
      {:ok, {_output, 48}} -> {:error, {:invalid_artifact_directory_type, :other}}
      {:ok, {output, status}} -> {:error, {:remote_command_failed, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_local_file(path, max_bytes) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          case IO.binread(file, max_bytes + 1) do
            :eof -> {:ok, ""}
            {:error, reason} -> {:error, reason}
            payload -> enforce_limit(payload, max_bytes)
          end
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enforce_limit(payload, max_bytes) when byte_size(payload) > max_bytes do
    {:error, {:artifact_too_large, max_bytes}}
  end

  defp enforce_limit(payload, _max_bytes), do: {:ok, payload}

  defp remote_read_result({:ok, {payload, 0}}, max_bytes), do: enforce_limit(payload, max_bytes)
  defp remote_read_result({:ok, {_output, 44}}, _max_bytes), do: :missing

  defp remote_read_result({:ok, {_output, 45}}, _max_bytes) do
    {:error, {:invalid_artifact_type, :symlink}}
  end

  defp remote_read_result({:ok, {_output, 46}}, _max_bytes) do
    {:error, {:invalid_artifact_type, :other}}
  end

  defp remote_read_result({:ok, {_output, 47}}, _max_bytes) do
    {:error, {:invalid_artifact_directory_type, :symlink}}
  end

  defp remote_read_result({:ok, {_output, 48}}, _max_bytes) do
    {:error, {:invalid_artifact_directory_type, :other}}
  end

  defp remote_read_result({:ok, {output, status}}, _max_bytes) do
    {:error, {:remote_command_failed, status, output}}
  end

  defp remote_read_result({:error, reason}, _max_bytes), do: {:error, reason}

  defp validate_local_artifact_directory(path, allow_missing) do
    case File.lstat(Path.dirname(path)) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, %{type: type}} -> {:error, {:invalid_artifact_directory_type, type}}
      {:error, :enoent} when allow_missing -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
