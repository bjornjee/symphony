defmodule SymphonyElixir.WorkflowBootstrap do
  @moduledoc """
  Generates runnable workflow files from a multi-workflow bootstrap manifest.
  """

  @type generated_workflow :: %{
          name: String.t(),
          output_path: Path.t(),
          config: map(),
          prompt: String.t()
        }

  @spec bootstrap(Path.t(), keyword()) :: {:ok, [generated_workflow()]} | {:error, term()}
  def bootstrap(manifest_path, opts \\ []) when is_binary(manifest_path) and is_list(opts) do
    with {:ok, manifest} <- load_manifest(manifest_path),
         {:ok, workflows} <- build_workflows(manifest, manifest_path) do
      if Keyword.get(opts, :check, false) do
        check_generated_files(workflows)
      else
        write_generated_files(workflows)
      end
    end
  end

  @spec render_workflow(map(), String.t()) :: String.t()
  def render_workflow(config, prompt) when is_map(config) and is_binary(prompt) do
    front_matter =
      config
      |> drop_internal_keys()
      |> encode_yaml()

    ["---\n", front_matter, "---\n\n", String.trim(prompt), "\n"]
    |> IO.iodata_to_binary()
  end

  defp load_manifest(manifest_path) do
    case File.read(manifest_path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, manifest} when is_map(manifest) -> {:ok, normalize_keys(manifest)}
          {:ok, _other} -> {:error, :bootstrap_manifest_not_a_map}
          {:error, reason} -> {:error, {:bootstrap_manifest_parse_error, reason}}
        end

      {:error, reason} ->
        {:error, {:bootstrap_manifest_not_found, manifest_path, reason}}
    end
  end

  defp build_workflows(manifest, manifest_path) do
    defaults = Map.get(manifest, "defaults", %{})
    prompt = Map.get(manifest, "prompt") || default_prompt()
    workflows = Map.get(manifest, "workflows")

    cond do
      not is_list(workflows) ->
        {:error, :bootstrap_workflows_missing}

      String.trim(to_string(prompt)) == "" ->
        {:error, :bootstrap_prompt_missing}

      true ->
        workflows
        |> Enum.map(&build_workflow(&1, defaults, to_string(prompt), Path.dirname(manifest_path)))
        |> collect_results()
    end
  end

  defp build_workflow(workflow, defaults, prompt, manifest_dir) when is_map(workflow) do
    workflow = normalize_keys(workflow)
    name = workflow["name"]
    output_path = workflow["output_path"]

    cond do
      not present_string?(name) ->
        {:error, :bootstrap_workflow_name_missing}

      not present_string?(output_path) ->
        {:error, {:bootstrap_workflow_output_path_missing, name}}

      true ->
        config =
          defaults
          |> deep_merge(Map.delete(workflow, "name"))
          |> deep_merge(derived_config(workflow))
          |> Map.delete("output_path")

        {:ok,
         %{
           name: name,
           output_path: expand_relative_path(output_path, manifest_dir),
           config: config,
           prompt: prompt
         }}
    end
  end

  defp build_workflow(_workflow, _defaults, _prompt, _manifest_dir), do: {:error, :bootstrap_workflow_not_a_map}

  defp derived_config(workflow) do
    repository = Map.get(workflow, "repository", %{})
    hooks = Map.get(workflow, "hooks", %{})

    case {Map.get(repository, "url"), Map.get(hooks, "after_create")} do
      {repo_url, nil} when is_binary(repo_url) ->
        %{"hooks" => %{"after_create" => "git clone #{shell_quote(repo_url)} ."}}

      _ ->
        %{}
    end
  end

  defp write_generated_files(workflows) do
    Enum.each(workflows, fn workflow ->
      File.mkdir_p!(Path.dirname(workflow.output_path))
      File.write!(workflow.output_path, render_workflow(workflow.config, workflow.prompt))
    end)

    {:ok, workflows}
  end

  defp check_generated_files(workflows) do
    stale =
      Enum.filter(workflows, fn workflow ->
        expected = render_workflow(workflow.config, workflow.prompt)

        case File.read(workflow.output_path) do
          {:ok, current} -> current != expected
          {:error, _reason} -> true
        end
      end)

    case stale do
      [] -> {:ok, workflows}
      stale -> {:error, {:bootstrap_outputs_stale, Enum.map(stale, & &1.output_path)}}
    end
  end

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, workflow}, {:ok, acc} -> {:cont, {:ok, [workflow | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, workflows} -> {:ok, Enum.reverse(workflows)}
      error -> error
    end
  end

  defp default_prompt do
    """
    You are working on Linear issue `{{ issue.identifier }}`.

    Issue context:
    Identifier: {{ issue.identifier }}
    Title: {{ issue.title }}
    Current status: {{ issue.state }}
    Labels: {{ issue.labels }}
    URL: {{ issue.url }}

    Description:
    {% if issue.description %}
    {{ issue.description }}
    {% else %}
    No description provided.
    {% endif %}
    """
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp expand_relative_path(path, root) when is_binary(path) and is_binary(root) do
    if Path.type(path) == :relative do
      Path.expand(path, root)
    else
      Path.expand(path)
    end
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp drop_internal_keys(config) do
    Map.drop(config, ["output_path", "repository"])
  end

  defp normalize_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {to_string(key), normalize_keys(nested_value)} end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp encode_yaml(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> encode_yaml_entry(key, value, 0) end)
    |> IO.iodata_to_binary()
  end

  defp encode_yaml_entry(key, value, indent) when is_map(value) do
    [indent(indent), key, ":\n", encode_yaml_map(value, indent + 2)]
  end

  defp encode_yaml_entry(key, value, indent) do
    [indent(indent), key, ": ", encode_yaml_value(value, indent), "\n"]
  end

  defp encode_yaml_map(map, indent) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> encode_yaml_entry(key, value, indent) end)
  end

  defp encode_yaml_value(value, indent) when is_binary(value) do
    if multiline?(value) do
      ["|\n", encode_multiline(value, indent + 2)]
    else
      inspect(value)
    end
  end

  defp encode_yaml_value(value, _indent) when is_integer(value), do: Integer.to_string(value)
  defp encode_yaml_value(true, _indent), do: "true"
  defp encode_yaml_value(false, _indent), do: "false"
  defp encode_yaml_value(nil, _indent), do: "null"

  defp encode_yaml_value(value, indent) when is_list(value) do
    if Enum.all?(value, &scalar?/1) do
      ["[", Enum.map_join(value, ", ", &encode_scalar/1), "]"]
    else
      ["\n", Enum.map(value, &encode_list_item(&1, indent + 2))]
    end
  end

  defp encode_yaml_value(value, _indent) when is_map(value), do: ["\n", encode_yaml_map(value, 2)]

  defp encode_list_item(value, indent) when is_map(value) do
    [indent(indent), "-\n", encode_yaml_map(value, indent + 2)]
  end

  defp encode_list_item(value, indent) do
    [indent(indent), "- ", encode_scalar(value), "\n"]
  end

  defp encode_multiline(value, indent) do
    value
    |> String.trim_trailing()
    |> String.split("\n", trim: false)
    |> Enum.map(fn line -> [indent(indent), line, "\n"] end)
  end

  defp encode_scalar(value) when is_binary(value), do: inspect(value)
  defp encode_scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_scalar(true), do: "true"
  defp encode_scalar(false), do: "false"
  defp encode_scalar(nil), do: "null"

  defp scalar?(value), do: is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value)

  defp multiline?(value), do: String.contains?(value, "\n")

  defp indent(count), do: String.duplicate(" ", count)

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
