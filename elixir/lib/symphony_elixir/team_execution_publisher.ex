defmodule SymphonyElixir.TeamExecutionPublisher do
  @moduledoc """
  Maintains one idempotent human-facing execution comment per Team Mode request.
  """

  import Bitwise, only: [&&&: 2, |||: 2]

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker

  @statuses ["Started", "Needs decision", "Finished"]

  @spec publish(Issue.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def publish(%Issue{id: issue_id} = issue, status, summary, opts \\ [])
      when is_binary(issue_id) and status in @statuses and is_map(summary) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    comment_id = comment_id(issue)
    body = render(issue, status, summary)

    with {:ok, existing} <- tracker.fetch_comment(issue_id, comment_id),
         :ok <- upsert(tracker, issue_id, comment_id, body, existing),
         {:ok, %{body: ^body}} <- tracker.fetch_comment(issue_id, comment_id) do
      :ok
    else
      {:ok, %{body: _other}} -> {:error, :team_execution_comment_mismatch}
      {:ok, nil} -> {:error, :team_execution_comment_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec comment_id(Issue.t()) :: String.t()
  def comment_id(%Issue{id: issue_id}) do
    digest = :crypto.hash(:sha256, Jason.encode!(["symphony-team-execution-v1", issue_id]))
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> = digest
    c = (c &&& 0x0FFF) ||| 0x4000
    d = (d &&& 0x3FFF) ||| 0x8000

    Enum.join([hex(a, 8), hex(b, 4), hex(c, 4), hex(d, 4), hex(e, 12)], "-")
  end

  @spec render(Issue.t(), String.t(), map()) :: String.t()
  def render(%Issue{} = issue, status, summary) do
    details =
      summary
      |> public_summary_lines()
      |> Enum.map_join("\n", &"- #{&1}")

    """
    ## Team execution

    Status: **#{status}**
    Request: `#{issue.identifier}`
    #{details}

    <!-- symphony-team-execution:v1 issue=#{issue.id} -->
    """
    |> String.trim()
  end

  defp upsert(tracker, issue_id, comment_id, body, nil),
    do: tracker.create_comment(issue_id, comment_id, body)

  defp upsert(_tracker, _issue_id, _comment_id, body, %{body: body}), do: :ok

  defp upsert(tracker, _issue_id, comment_id, body, %{body: _old_body}),
    do: tracker.update_comment(comment_id, body)

  defp public_summary_lines(summary) do
    repositories = Map.get(summary, :repositories) || Map.get(summary, "repositories") || []
    reason = Map.get(summary, :reason) || Map.get(summary, "reason")
    members = Map.get(summary, :members) || Map.get(summary, "members") || %{}

    []
    |> maybe_add("Repositories: #{Enum.join(repositories, ", ")}", repositories != [])
    |> maybe_add("Decision needed: #{reason}", is_binary(reason) and reason != "")
    |> Kernel.++(member_lines(members))
  end

  defp member_lines(members) when is_map(members) do
    members
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {workflow, member} ->
      pr_url = member[:pull_request_url] || member["pull_request_url"] || "PR unavailable"
      "#{workflow}: #{pr_url}"
    end)
  end

  defp maybe_add(lines, _line, false), do: lines
  defp maybe_add(lines, line, true), do: lines ++ [line]

  defp hex(value, width), do: value |> Integer.to_string(16) |> String.pad_leading(width, "0")
end
