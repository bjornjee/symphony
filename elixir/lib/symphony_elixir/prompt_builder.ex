defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]
  @agent_dashboard_workflow ~r/\$?agent-dashboard:(chore|feature|fix|refactor|pr|investigate|implement|rca)\b/i
  @agent_dashboard_prompt_start ~r/^\$agent-dashboard:(chore|feature|fix|refactor|pr|investigate|implement|rca)\b/i

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
    |> maybe_prepend_agent_dashboard_invocation(issue)
  end

  defp maybe_prepend_agent_dashboard_invocation(prompt, issue) when is_binary(prompt) do
    cond do
      Regex.match?(@agent_dashboard_prompt_start, String.trim_leading(prompt)) ->
        prompt

      workflow = agent_dashboard_workflow(issue) ->
        "$agent-dashboard:#{workflow}\n\n#{prompt}"

      true ->
        prompt
    end
  end

  defp agent_dashboard_workflow(%{description: description}) when is_binary(description) do
    case Regex.run(@agent_dashboard_workflow, description) do
      [_match, workflow] -> String.downcase(workflow)
      _ -> nil
    end
  end

  defp agent_dashboard_workflow(_issue), do: nil

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
