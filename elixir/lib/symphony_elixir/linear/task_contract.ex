defmodule SymphonyElixir.Linear.TaskContract do
  @moduledoc """
  Deterministically validates and fingerprints a Codex Agent Task v1 issue.
  """

  alias SymphonyElixir.Linear.Issue

  @version 1
  @required_headings [
    "Goal",
    "Context",
    "Scope",
    "Acceptance Criteria",
    "Verification",
    "Risk"
  ]
  @optional_headings ["Notes For Agent"]
  @all_headings @required_headings ++ @optional_headings
  @max_acceptance_criteria 100

  defstruct [:version, :digest, :title, :description, :sections, :acceptance_criteria, :source_updated_at]

  @type acceptance_criterion :: %{id: String.t(), text: String.t()}

  @type t :: %__MODULE__{
          version: pos_integer(),
          digest: String.t(),
          title: String.t(),
          description: String.t(),
          sections: %{required(String.t()) => String.t()},
          acceptance_criteria: [acceptance_criterion()],
          source_updated_at: DateTime.t() | nil
        }

  @spec from_issue(Issue.t()) :: {:ok, t()} | {:error, [String.t()]}
  def from_issue(%Issue{} = issue) do
    title = canonicalize_title(issue.title)
    description = canonicalize_description(issue.description)
    {headings, scan_errors} = scan_headings(description)
    sections = extract_sections(description, headings)

    errors =
      scan_errors ++
        title_errors(title) ++
        heading_errors(headings) ++
        section_errors(sections)

    case errors do
      [] ->
        {:ok,
         %__MODULE__{
           version: @version,
           digest: digest(title, description),
           title: title,
           description: description,
           sections: sections,
           acceptance_criteria: parse_acceptance_criteria(Map.fetch!(sections, "Acceptance Criteria")),
           source_updated_at: issue.updated_at
         }}

      errors ->
        {:error, Enum.uniq(errors)}
    end
  end

  @spec version() :: pos_integer()
  def version, do: @version

  defp canonicalize_title(title) when is_binary(title) do
    title
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
    |> String.trim()
  end

  defp canonicalize_title(_title), do: ""

  defp canonicalize_description(description) when is_binary(description) do
    description
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
    |> String.trim()
  end

  defp canonicalize_description(_description), do: ""

  defp scan_headings(description) do
    description
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.reduce({false, [], []}, fn {line, line_number}, {in_fence, headings, errors} ->
      cond do
        fence_line?(line) ->
          {!in_fence, headings, errors}

        in_fence ->
          {in_fence, headings, errors}

        true ->
          scan_visible_heading(line, line_number, in_fence, headings, errors)
      end
    end)
    |> then(fn {_in_fence, headings, errors} -> {headings, errors} end)
  end

  defp scan_visible_heading(line, line_number, in_fence, headings, errors) do
    case Regex.run(~r/^##\s+(.+?)\s*$/, line, capture: :all_but_first) do
      [heading] when heading in @all_headings ->
        {in_fence, headings ++ [{heading, line_number}], errors}

      [heading] ->
        {in_fence, headings, errors ++ ["Unexpected level-two heading: ## #{heading}"]}

      _ ->
        {in_fence, headings, errors}
    end
  end

  defp fence_line?(line), do: Regex.match?(~r/^\s*(?:`{3,}|~{3,})/, line)

  defp extract_sections(description, headings) do
    lines = String.split(description, "\n")

    headings
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {{heading, line_number}, index}, sections ->
      next_line_number =
        case Enum.at(headings, index + 1) do
          {_next_heading, next_heading_line} -> next_heading_line
          nil -> length(lines)
        end

      content =
        lines
        |> Enum.slice((line_number + 1)..(next_line_number - 1)//1)
        |> Enum.join("\n")
        |> String.trim()

      Map.put_new(sections, heading, content)
    end)
  end

  defp title_errors(""), do: ["Issue title cannot be empty."]
  defp title_errors(_title), do: []

  defp heading_errors(headings) do
    names = Enum.map(headings, &elem(&1, 0))

    missing_errors =
      @required_headings
      |> Enum.reject(&(&1 in names))
      |> Enum.map(&"Missing required heading: ## #{&1}")

    duplicate_errors =
      names
      |> Enum.frequencies()
      |> Enum.filter(fn {_heading, count} -> count > 1 end)
      |> Enum.map(fn {heading, _count} -> "Duplicate heading: ## #{heading}" end)

    present_order = Enum.filter(@all_headings, &(&1 in names))
    order_errors = if names == present_order, do: [], else: ["Required headings are out of order."]

    missing_errors ++ duplicate_errors ++ order_errors
  end

  defp section_errors(sections) do
    @all_headings
    |> Enum.reduce([], fn heading, errors ->
      case Map.fetch(sections, heading) do
        {:ok, content} ->
          errors ++ empty_section_errors(heading, content) ++ placeholder_errors(heading, content)

        :error ->
          errors
      end
    end)
    |> Kernel.++(scope_errors(Map.get(sections, "Scope")))
    |> Kernel.++(acceptance_criteria_errors(Map.get(sections, "Acceptance Criteria")))
    |> Kernel.++(risk_errors(Map.get(sections, "Risk")))
  end

  defp empty_section_errors(heading, ""), do: ["Section cannot be empty: ## #{heading}"]
  defp empty_section_errors(_heading, _content), do: []

  defp placeholder_errors(heading, content) do
    if Regex.match?(~r/<[^>\n]+>|<!--|^\s*(?:TBD|TODO|TBC|\?\?\?)\s*$/im, content) do
      ["Section contains placeholder content: ## #{heading}"]
    else
      []
    end
  end

  defp scope_errors(nil), do: []

  defp scope_errors(scope) do
    []
    |> require_scope_list(scope, "In", ~r/^In:\s*\n(.*?)(?=^Out:\s*$)/ms)
    |> require_scope_list(scope, "Out", ~r/^Out:\s*\n(.*)\z/ms)
  end

  defp require_scope_list(errors, scope, label, pattern) do
    case Regex.run(pattern, scope, capture: :all_but_first) do
      [content] ->
        if Regex.match?(~r/^[*+-]\s+\S/m, content) do
          errors
        else
          errors ++ ["Section must include #{label} with at least one bullet: ## Scope"]
        end

      _ ->
        errors ++ ["Section must include #{label} with at least one bullet: ## Scope"]
    end
  end

  defp acceptance_criteria_errors(nil), do: []

  defp acceptance_criteria_errors(content) do
    lines = content |> String.split("\n") |> Enum.reject(&(String.trim(&1) == ""))
    criteria = parse_acceptance_criteria(content)

    cond do
      not Enum.any?(lines, &Regex.match?(~r/^- \[[ xX]\] \S/, &1)) ->
        ["Section must include at least one checkbox: ## Acceptance Criteria"]

      not Enum.all?(lines, &Regex.match?(~r/^- \[[ xX]\] \S/, &1)) ->
        ["Every acceptance criterion must be a checkbox item."]

      length(criteria) > @max_acceptance_criteria ->
        ["Acceptance Criteria cannot contain more than #{@max_acceptance_criteria} items."]

      criteria |> Enum.map(& &1.id) |> Enum.uniq() |> length() != length(criteria) ->
        ["Acceptance criteria must be unique."]

      true ->
        []
    end
  end

  defp parse_acceptance_criteria(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^- \[[ xX]\] (\S.*)$/, line, capture: :all_but_first) do
        [text] -> [%{id: criterion_id(text), text: text}]
        _ -> []
      end
    end)
  end

  defp criterion_id(text) do
    [@version, "acceptance_criterion", text]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("ac-" <> &1))
  end

  defp risk_errors(nil), do: []

  defp risk_errors(content) do
    if String.downcase(String.trim(content)) in ["low", "medium", "high"] do
      []
    else
      ["Risk must be one of: low, medium, high"]
    end
  end

  defp digest(title, description) do
    [@version, title, description]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
