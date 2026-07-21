defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Issue

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec create_comment(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, comment_id, body) do
    comments = Process.get({__MODULE__, :comments}, %{})
    Process.put({__MODULE__, :comments}, Map.put_new(comments, {issue_id, comment_id}, body))
    send_event({:memory_tracker_comment, issue_id, comment_id, body})
    :ok
  end

  @spec fetch_comment(String.t(), String.t()) ::
          {:ok, %{id: String.t(), body: String.t()} | nil} | {:error, term()}
  def fetch_comment(issue_id, comment_id) do
    case Process.get({__MODULE__, :comments}, %{}) do
      %{{^issue_id, ^comment_id} => body} -> {:ok, %{id: comment_id, body: body}}
      _ -> {:ok, nil}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    updated_issues =
      Enum.map(configured_issues(), fn
        %Issue{id: ^issue_id} = issue -> %{issue | state: state_name}
        issue -> issue
      end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, updated_issues)
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  @spec cleanup_issue_labels(Issue.t(), [String.t()]) :: :ok | {:error, term()}
  def cleanup_issue_labels(%Issue{id: issue_id}, label_names) when is_list(label_names) do
    send_event({:memory_tracker_label_cleanup, issue_id, label_names})
    Application.get_env(:symphony_elixir, :memory_tracker_cleanup_result, :ok)
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
