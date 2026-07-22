defmodule SymphonyElixir.ExecutionLedger do
  @moduledoc "Immutable engine-owned execution receipts stored outside issue workspaces."

  alias SymphonyElixir.PlanningArtifact

  @max_receipt_bytes 1_048_576
  @component ~r/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/

  @spec key(String.t(), String.t(), String.t()) :: String.t()
  def key(origin, issue_id, plan_digest) do
    [origin, issue_id, plan_digest]
    |> PlanningArtifact.digest()
  end

  @spec create(String.t(), String.t(), String.t(), map()) :: {:ok, map()} | :exists | {:error, term()}
  def create(key, kind, id, receipt) when is_map(receipt) do
    with :ok <- components([key, kind, id]) do
      persisted = Map.put(receipt, "receipt_digest", PlanningArtifact.digest(receipt))
      payload = Jason.encode!(persisted, pretty: true) <> "\n"

      if byte_size(payload) > @max_receipt_bytes,
        do: {:error, :receipt_too_large},
        else: create_exclusive(path(key, kind, id), payload, persisted)
    end
  end

  @spec read(String.t(), String.t(), String.t()) :: :missing | {:ok, map()} | {:error, term()}
  def read(key, kind, id) do
    with :ok <- components([key, kind, id]) do
      case File.read(path(key, kind, id)) do
        {:ok, payload} when byte_size(payload) <= @max_receipt_bytes -> decode_and_verify(payload)
        {:ok, _payload} -> {:error, :receipt_too_large}
        {:error, :enoent} -> :missing
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec read_required(String.t(), String.t(), String.t(), atom(), atom()) ::
          {:ok, map()} | {:error, term()}
  def read_required(key, kind, id, missing_error, invalid_error)
      when is_atom(missing_error) and is_atom(invalid_error) do
    case read(key, kind, id) do
      {:ok, receipt} -> {:ok, receipt}
      :missing -> {:error, missing_error}
      {:error, reason} -> {:error, {invalid_error, reason}}
    end
  end

  @spec path(String.t(), String.t(), String.t()) :: Path.t()
  def path(key, kind, id), do: Path.join([root(), key, kind, id <> ".json"])

  @spec list(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(key, kind) do
    with :ok <- components([key, kind]) do
      directory = Path.join([root(), key, kind])

      case File.ls(directory) do
        {:ok, names} when length(names) <= 256 -> read_receipts(key, kind, Enum.sort(names))
        {:ok, _names} -> {:error, :too_many_receipts}
        {:error, :enoent} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp root do
    Application.get_env(:symphony_elixir, :execution_state_root) ||
      :filename.basedir(:user_data, "symphony") |> to_string() |> Path.join("execution")
  end

  defp components(values) do
    if Enum.all?(values, &(is_binary(&1) and Regex.match?(@component, &1))), do: :ok, else: {:error, :invalid_ledger_component}
  end

  defp create_exclusive(path, payload, persisted) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case File.write(path, payload, [:write, :exclusive]) do
        :ok ->
          File.chmod(path, 0o600)
          {:ok, persisted}

        {:error, :eexist} ->
          :exists

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp decode_and_verify(payload) do
    with {:ok, receipt} when is_map(receipt) <- Jason.decode(payload),
         digest when is_binary(digest) <- receipt["receipt_digest"],
         true <- digest == PlanningArtifact.digest(Map.delete(receipt, "receipt_digest")) do
      {:ok, receipt}
    else
      _ -> {:error, :invalid_receipt}
    end
  end

  defp read_receipts(key, kind, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, receipts} ->
      case read_receipt_name(key, kind, name) do
        {:ok, receipt} -> {:cont, {:ok, receipts ++ [receipt]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp read_receipt_name(key, kind, name) do
    if String.ends_with?(name, ".json") do
      case read(key, kind, String.trim_trailing(name, ".json")) do
        {:ok, receipt} -> {:ok, receipt}
        {:error, reason} -> {:error, reason}
        :missing -> {:error, :receipt_disappeared}
      end
    else
      {:error, :invalid_receipt_filename}
    end
  end
end
