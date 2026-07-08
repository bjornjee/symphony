defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]
  @agent_dashboard_workflow ~r/\$?agent-dashboard:(chore|feature|fix|refactor|pr|investigate|implement|rca)\b/i
  @agent_dashboard_prompt_start ~r/^\$agent-dashboard:(chore|feature|fix|refactor|pr|investigate|implement|rca)\b/i
  @direct_agent_dashboard_workflows ~w(chore fix refactor pr investigate implement rca)

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
    if Regex.match?(@agent_dashboard_prompt_start, String.trim_leading(prompt)) do
      prompt
    else
      case agent_dashboard_workflow(issue) do
        workflow when workflow in @direct_agent_dashboard_workflows ->
          "$agent-dashboard:#{workflow}\n\n#{prompt}"

        "feature" ->
          "#{unattended_feature_contract()}\n\n#{prompt}"

        _ ->
          prompt
      end
    end
  end

  defp unattended_feature_contract do
    """
    Symphony selected `agent-dashboard:feature`, but this is an unattended Codex
    app-server run and cannot enter Codex Plan Mode. Do not invoke
    `$agent-dashboard:feature` from this session.

    Follow this Symphony-compatible feature contract instead:

    - create an isolated git worktree from latest `main` with a `feat/<name>` branch
    - copy and validate `.env*` parity when source repo env files exist
    - keep planning and invariant notes in `.symphony/workpad.md`, not Linear
    - keep a phase-level run audit in `.symphony/run-audit.md` with commands, durations, proof gaps, and handoff timing
    - state execution context, scale shape, verification profile, and proof command before editing
    - use the smallest sufficient proof during the edit loop; record known unrelated broad-gate failures once instead of retrying blindly
    - use RED/GREEN/REFACTOR when changing behavior and a test adds value
    - make the smallest scoped implementation, commit with `feat:`, and open a PR
    - before moving the Linear issue to `Human Review`, leave exactly one human-facing comment with a PR URL or a real external blocker plus a concise audit summary
    """
    |> String.trim()
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
