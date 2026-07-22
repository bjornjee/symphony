defmodule SymphonyElixir.HumanReviewBlocker do
  @moduledoc "Publishes one deterministic read-back-verified Human Review blocker."

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker

  @spec publish(Issue.t(), [String.t()], String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def publish(%Issue{} = issue, key_parts, body, opts \\ []) when is_list(key_parts) and is_binary(body) do
    id = deterministic_uuid([issue.id | key_parts])
    tracker = Keyword.get(opts, :tracker, Tracker)
    state = Keyword.get_lazy(opts, :handoff_state, fn -> Config.settings!().tracker.handoff_state end)

    with :ok <- ensure_comment(tracker, issue.id, id, body),
         :ok <- tracker.update_issue_state(issue.id, state),
         {:ok, [%Issue{state: actual} | _]} <- tracker.fetch_issue_states_by_ids([issue.id]),
         true <- String.downcase(actual) == String.downcase(state) || {:error, :human_review_state_readback_failed} do
      {:ok, id}
    end
  end

  defp ensure_comment(tracker, issue_id, id, body) do
    case tracker.fetch_comment(issue_id, id) do
      {:ok, nil} ->
        with :ok <- tracker.create_comment(issue_id, id, body),
             {:ok, %{id: ^id, body: ^body}} <- tracker.fetch_comment(issue_id, id),
             do: :ok

      {:ok, %{id: ^id, body: ^body}} ->
        :ok

      _ ->
        {:error, :human_review_comment_readback_failed}
    end
  end

  defp deterministic_uuid(values) do
    <<a::32, b::16, c::16, d::16, e::48, _::binary>> = :crypto.hash(:sha256, values)

    Enum.join(
      [
        hex(a, 8),
        hex(b, 4),
        hex(Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000), 4),
        hex(Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000), 4),
        hex(e, 12)
      ],
      "-"
    )
  end

  defp hex(value, width), do: value |> Integer.to_string(16) |> String.pad_leading(width, "0")
end
