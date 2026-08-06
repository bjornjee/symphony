defmodule SymphonyElixir.Linear.TeamContract do
  @moduledoc """
  Validates the bounded, ticket-authored Team Mode contract against a trusted repository registry.
  """

  @allowed_keys ~w(repositories validation_goal invariants)
  @repository_allowed_keys ~w(workflow change acceptance verification)
  @min_repositories 2
  @max_repositories 8

  defmodule Repository do
    @moduledoc false

    defstruct [:agent_id, :workflow, :change, :acceptance, :verification, :trusted_config]

    @type t :: %__MODULE__{
            agent_id: String.t(),
            workflow: String.t(),
            change: String.t(),
            acceptance: [String.t()],
            verification: [String.t()],
            trusted_config: map()
          }
  end

  defstruct [:request_id, :digest, :repositories, :validation_goal, :invariants]

  @type t :: %__MODULE__{
          request_id: String.t(),
          digest: String.t(),
          repositories: [Repository.t()],
          validation_goal: String.t(),
          invariants: [String.t()]
        }

  @spec parse(String.t(), String.t(), String.t(), map()) :: {:ok, t()} | {:error, [String.t()]}
  def parse(section, request_id, digest, trusted_registry)
      when is_binary(section) and is_binary(request_id) and is_binary(digest) and is_map(trusted_registry) do
    with {:ok, decoded} <- decode(section) do
      decoded = normalize_keys(decoded)
      raw_repositories = Map.get(decoded, "repositories")
      {repositories, repository_errors} = parse_repositories(raw_repositories, trusted_registry)

      errors =
        unsupported_keys(decoded, @allowed_keys, "Team contains unsupported keys: ") ++
          repository_count_errors(raw_repositories) ++
          repository_errors ++
          duplicate_workflow_errors(repositories) ++
          required_string_errors(decoded, "validation_goal", "Team validation_goal must be non-empty.") ++
          string_list_errors(decoded, "invariants", "Team invariants must contain at least one non-empty item.")

      case Enum.uniq(errors) do
        [] ->
          {:ok,
           %__MODULE__{
             request_id: request_id,
             digest: digest,
             repositories: repositories,
             validation_goal: String.trim(decoded["validation_goal"]),
             invariants: normalize_string_list(decoded["invariants"])
           }}

        errors ->
          {:error, errors}
      end
    end
  end

  defp decode(section) do
    case YamlElixir.read_from_string(section) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, ["Team YAML must decode to a map."]}
      {:error, _reason} -> {:error, ["Team YAML is invalid."]}
    end
  end

  defp parse_repositories(repositories, trusted_registry) when is_list(repositories) do
    repositories
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {raw_repository, index}, {parsed, errors} ->
      case parse_repository(raw_repository, index, trusted_registry) do
        {:ok, repository, repository_errors} ->
          {parsed ++ [repository], errors ++ repository_errors}

        {:error, repository_errors} ->
          {parsed, errors ++ repository_errors}
      end
    end)
  end

  defp parse_repositories(_repositories, _trusted_registry), do: {[], []}

  defp parse_repository(raw_repository, index, trusted_registry) when is_map(raw_repository) do
    repository = normalize_keys(raw_repository)
    workflow = normalize_string(repository["workflow"])
    display = if workflow == "", do: "at index #{index}", else: workflow
    trusted_config = Map.get(trusted_registry, workflow)

    errors =
      unsupported_keys(
        repository,
        @repository_allowed_keys,
        "Team repository #{display} contains unsupported keys: "
      ) ++
        required_string_errors(
          repository,
          "workflow",
          "Team repository at index #{index} workflow must be non-empty."
        ) ++
        unknown_workflow_errors(workflow, trusted_config) ++
        required_string_errors(
          repository,
          "change",
          "Team repository #{display} change must be non-empty."
        ) ++
        string_list_errors(
          repository,
          "acceptance",
          "Team repository #{display} acceptance must contain at least one non-empty item."
        ) ++
        string_list_errors(
          repository,
          "verification",
          "Team repository #{display} verification must contain at least one non-empty item."
        )

    if workflow == "" do
      {:error, errors}
    else
      {:ok,
       %Repository{
         agent_id: "repo:" <> workflow,
         workflow: workflow,
         change: normalize_string(repository["change"]),
         acceptance: normalize_string_list(repository["acceptance"]),
         verification: normalize_string_list(repository["verification"]),
         trusted_config: trusted_config
       }, errors}
    end
  end

  defp parse_repository(_raw_repository, index, _trusted_registry) do
    {:error, ["Team repository at index #{index} must be a map."]}
  end

  defp repository_count_errors(repositories)
       when is_list(repositories) and length(repositories) in @min_repositories..@max_repositories,
       do: []

  defp repository_count_errors(_repositories),
    do: ["Team mode requires between #{@min_repositories} and #{@max_repositories} repositories."]

  defp duplicate_workflow_errors(repositories) do
    workflows = Enum.map(repositories, & &1.workflow)

    if length(workflows) == length(Enum.uniq(workflows)) do
      []
    else
      ["Team repositories must use unique workflows."]
    end
  end

  defp unknown_workflow_errors("", _trusted_config), do: []
  defp unknown_workflow_errors(workflow, nil), do: ["Unknown Team workflow: #{workflow}"]
  defp unknown_workflow_errors(_workflow, trusted_config) when is_map(trusted_config), do: []
  defp unknown_workflow_errors(workflow, _trusted_config), do: ["Invalid trusted Team workflow: #{workflow}"]

  defp unsupported_keys(map, allowed_keys, prefix) do
    unsupported = map |> Map.keys() |> Enum.reject(&(&1 in allowed_keys)) |> Enum.sort()
    if unsupported == [], do: [], else: [prefix <> Enum.join(unsupported, ", ")]
  end

  defp required_string_errors(map, key, error) do
    if normalize_string(map[key]) == "", do: [error], else: []
  end

  defp string_list_errors(map, key, error) do
    case map[key] do
      values when is_list(values) ->
        normalized = normalize_string_list(values)

        if normalized != [] and length(normalized) == length(values) do
          []
        else
          [error]
        end

      _other ->
        [error]
    end
  end

  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(_value), do: ""

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(_values), do: []

  defp normalize_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_keys(nested)} end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value
end
