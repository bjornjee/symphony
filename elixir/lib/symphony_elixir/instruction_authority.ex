defmodule SymphonyElixir.InstructionAuthority do
  @moduledoc """
  Captures the ordered instruction files reported by Codex as execution authority.
  """

  alias SymphonyElixir.{PlanningArtifact, WorkspaceArtifact}

  @max_sources 32
  @max_source_bytes 1_048_576
  @max_total_bytes 4_194_304

  @type t :: %{paths: [Path.t()], digest: String.t(), worker_host: String.t() | nil}

  @spec capture([map()], String.t() | nil) :: {:ok, t()} | {:error, term()}
  def capture(sources, worker_host \\ nil) when is_list(sources) do
    with {:ok, paths} <- paths(sources),
         {:ok, entries} <- read_all(paths, worker_host),
         :ok <- total_size(entries) do
      {:ok,
       %{
         paths: paths,
         digest: PlanningArtifact.digest(Enum.map(entries, fn {path, body} -> [path, body] end)),
         worker_host: worker_host
       }}
    end
  end

  @spec revalidate(t()) :: :ok | {:error, term()}
  def revalidate(%{paths: paths, digest: digest, worker_host: worker_host}) do
    case capture(Enum.map(paths, &%{"path" => &1}), worker_host) do
      {:ok, %{digest: ^digest}} -> :ok
      {:ok, _changed} -> {:error, :instruction_drift}
      {:error, reason} -> {:error, {:instruction_revalidation_failed, reason}}
    end
  end

  defp paths(sources) when length(sources) > @max_sources, do: {:error, :too_many_instruction_sources}

  defp paths(sources) do
    paths = Enum.map(sources, &source_path/1)

    cond do
      Enum.any?(paths, &is_nil/1) -> {:error, :invalid_instruction_source}
      Enum.uniq(paths) != paths -> {:error, :duplicate_instruction_source}
      true -> {:ok, paths}
    end
  end

  defp source_path(%{"path" => path}) when is_binary(path) and byte_size(path) in 1..4096, do: path
  defp source_path(%{path: path}) when is_binary(path) and byte_size(path) in 1..4096, do: path
  defp source_path(_source), do: nil

  defp read_all(paths, worker_host) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, entries} ->
      case WorkspaceArtifact.read(path, @max_source_bytes, worker_host) do
        {:ok, body} -> {:cont, {:ok, [{path, body} | entries]}}
        :missing -> {:halt, {:error, {:instruction_source_missing, path}}}
        {:error, reason} -> {:halt, {:error, {:instruction_source_unreadable, path, reason}}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp total_size(entries) do
    if Enum.reduce(entries, 0, fn {_path, body}, total -> total + byte_size(body) end) <= @max_total_bytes,
      do: :ok,
      else: {:error, :instruction_sources_too_large}
  end
end
