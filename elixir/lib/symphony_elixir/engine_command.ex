defmodule SymphonyElixir.EngineCommand do
  @moduledoc "Runs one engine-owned proof command with hard time and output bounds."

  alias SymphonyElixir.SSH

  @output_limit 1_048_576
  @tail_limit 8_192

  @spec run(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(directory, command, opts \\ []) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, port} <- start(directory, command, worker_host) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      collect(port, deadline, :crypto.hash_init(:sha256), 0, "")
    end
  end

  defp start(directory, command, nil) do
    case System.find_executable("sh") do
      nil ->
        {:error, :shell_not_found}

      executable ->
        {:ok,
         Port.open({:spawn_executable, String.to_charlist(executable)}, [
           :binary,
           :exit_status,
           :stderr_to_stdout,
           args: [~c"-lc", String.to_charlist(command)],
           cd: String.to_charlist(directory)
         ])}
    end
  end

  defp start(directory, command, worker_host) do
    SSH.start_port(worker_host, "cd #{shell_escape(directory)} && #{command}")
  end

  defp collect(port, deadline, hash, size, tail) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        new_size = size + byte_size(data)

        if new_size > @output_limit do
          close_port(port)
          {:error, failure(:output_limit_exceeded, hash, size, tail)}
        else
          collect(port, deadline, :crypto.hash_update(hash, data), new_size, keep_tail(tail <> data))
        end

      {^port, {:exit_status, status}} ->
        {:ok,
         %{
           exit_status: status,
           output_bytes: size,
           output_hash: hash |> :crypto.hash_final() |> Base.encode16(case: :lower),
           output_tail: tail
         }}
    after
      remaining ->
        close_port(port)
        {:error, failure(:timeout, hash, size, tail)}
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp keep_tail(value) when byte_size(value) <= @tail_limit, do: value
  defp keep_tail(value), do: binary_part(value, byte_size(value) - @tail_limit, @tail_limit)

  defp failure(reason, hash, size, tail) do
    %{
      reason: reason,
      output_bytes: size,
      output_hash: hash |> :crypto.hash_final() |> Base.encode16(case: :lower),
      output_tail: tail
    }
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
