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

    with :ok <- validate_transition_source(tracker, issue.id, issue.state, state),
         :ok <- ensure_comment(tracker, issue.id, id, body),
         :ok <- transition_issue(tracker, issue.id, issue.state, state) do
      {:ok, id}
    end
  end

  defp validate_transition_source(tracker, issue_id, expected_source, target) do
    with {:ok, current} <- current_state(tracker, issue_id) do
      if same_state?(current, expected_source) or same_state?(current, target),
        do: :ok,
        else: {:error, {:human_review_state_source_mismatch, expected_source, current, target}}
    end
  end

  defp transition_issue(tracker, issue_id, expected_source, target) do
    with {:ok, current} <- current_state(tracker, issue_id) do
      cond do
        same_state?(current, target) ->
          :ok

        same_state?(current, expected_source) ->
          update_and_verify_state(tracker, issue_id, target)

        true ->
          {:error, {:human_review_state_source_mismatch, expected_source, current, target}}
      end
    end
  end

  defp update_and_verify_state(tracker, issue_id, target) do
    update_result = tracker.update_issue_state(issue_id, target)

    case current_state(tracker, issue_id) do
      {:ok, actual} ->
        if same_state?(actual, target),
          do: :ok,
          else: {:error, {:human_review_state_transition_unverified, target, actual, update_result}}

      {:error, reason} ->
        {:error, {:human_review_state_readback_failed, reason, update_result}}
    end
  end

  defp current_state(tracker, issue_id) do
    case tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{state: state} | _]} when is_binary(state) -> {:ok, state}
      {:ok, []} -> {:error, :human_review_issue_missing}
      {:error, reason} -> {:error, {:human_review_state_read_failed, reason}}
      other -> {:error, {:human_review_state_read_invalid, other}}
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

  defp same_state?(left, right) when is_binary(left) and is_binary(right),
    do: String.downcase(left) == String.downcase(right)

  defp same_state?(_left, _right), do: false

  defp hex(value, width), do: value |> Integer.to_string(16) |> String.pad_leading(width, "0")
end
