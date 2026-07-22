defmodule SymphonyElixir.WorkflowProfile do
  @moduledoc """
  Selects and loads a trusted engineering workflow for a task contract.
  """

  alias SymphonyElixir.Linear.TaskContract

  @version 1
  @names ~w(feature fix refactor chore pr)
  @title_prefixes %{
    "feat" => "feature",
    "fix" => "fix",
    "refactor" => "refactor",
    "chore" => "chore",
    "docs" => "chore",
    "ci" => "chore",
    "build" => "chore",
    "pr" => "pr"
  }

  defstruct [:name, :version, :digest, :instructions]

  @type t :: %__MODULE__{
          name: String.t(),
          version: pos_integer(),
          digest: String.t(),
          instructions: String.t()
        }

  @spec select(TaskContract.t()) :: {:ok, t()} | {:error, term()}
  def select(%TaskContract{} = contract) do
    case selected_name(contract) do
      {:ok, name} -> load(name)
      {:error, _reason} = error -> error
    end
  end

  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(name) when name in @names do
    common = read_profile!("common")
    specific = read_profile!(name)
    instructions = String.trim(common) <> "\n\n" <> String.trim(specific)

    digest =
      [@version, name, instructions]
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    {:ok,
     %__MODULE__{
       name: name,
       version: @version,
       digest: digest,
       instructions: instructions
     }}
  end

  def load(name) when is_binary(name), do: {:error, {:unsupported_workflow_profile, name}}

  defp selected_name(%TaskContract{} = contract) do
    notes = Map.get(contract.sections, "Notes For Agent", "")

    case explicit_directives(notes) do
      [] -> title_workflow(contract.title)
      [name] when name in @names -> {:ok, name}
      [name] -> {:error, {:unsupported_workflow_profile, name}}
      _multiple -> {:error, :ambiguous_workflow_profile}
    end
  end

  defp explicit_directives(notes) do
    ~r/^Workflow:\s*([^\s]+)\s*$/m
    |> Regex.scan(notes, capture: :all_but_first)
    |> Enum.map(fn [name] -> String.downcase(name) end)
  end

  defp title_workflow(title) do
    case Regex.run(~r/^([a-z]+):\s+\S/i, title, capture: :all_but_first) do
      [prefix] ->
        case Map.fetch(@title_prefixes, String.downcase(prefix)) do
          {:ok, name} -> {:ok, name}
          :error -> {:error, :workflow_profile_missing}
        end

      _ ->
        {:error, :workflow_profile_missing}
    end
  end

  defp read_profile!(name) do
    priv_dir = :symphony_elixir |> :code.priv_dir() |> to_string()

    [priv_dir, "workflow_profiles", "#{name}.md"]
    |> Path.join()
    |> File.read!()
  end
end
