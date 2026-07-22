defmodule SymphonyElixir.EngineCommand do
  @moduledoc "Runs one engine-owned proof command with hard time and output bounds."

  @output_limit 1_048_576
  @tail_limit 8_192

  @spec run(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(directory, command, opts \\ []) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)

    case Keyword.get(opts, :executor) do
      executor when is_function(executor, 3) ->
        execute(executor, directory, command, timeout_ms)

      _ ->
        {:error, :sandbox_executor_required}
    end
  end

  defp execute(executor, directory, command, timeout_ms) do
    case executor.(directory, command, timeout_ms: timeout_ms, output_bytes_cap: @output_limit) do
      {:ok, %{exit_status: status, stdout: stdout, stderr: stderr}}
      when is_integer(status) and is_binary(stdout) and is_binary(stderr) ->
        result(status, stdout <> stderr)

      {:ok, payload} ->
        {:error, failure(inspect({:invalid_sandbox_result, payload}), "")}

      {:error, :timeout} ->
        {:error, failure(:timeout, "")}

      {:error, reason} ->
        {:error, failure(inspect(reason), "")}
    end
  end

  defp result(status, output) when byte_size(output) <= @output_limit do
    {:ok,
     %{
       exit_status: status,
       output_bytes: byte_size(output),
       output_hash: digest(output),
       output_tail: keep_tail(output)
     }}
  end

  defp result(_status, output), do: {:error, failure(:output_limit_exceeded, output)}

  defp keep_tail(value) when byte_size(value) <= @tail_limit, do: value
  defp keep_tail(value), do: binary_part(value, byte_size(value) - @tail_limit, @tail_limit)

  defp failure(reason, output) do
    %{
      reason: reason,
      output_bytes: byte_size(output),
      output_hash: digest(output),
      output_tail: keep_tail(output)
    }
  end

  defp digest(output), do: :crypto.hash(:sha256, output) |> Base.encode16(case: :lower)
end
