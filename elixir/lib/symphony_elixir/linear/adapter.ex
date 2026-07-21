defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.{Client, Issue}

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @create_idempotent_comment_mutation """
  mutation SymphonyCreateIdempotentComment($issueId: String!, $commentId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, id: $commentId, body: $body}) {
      success
    }
  }
  """

  @comment_read_query """
  query SymphonyReadIssueComment($issueId: String!, $commentId: ID!, $first: Int!) {
    issue(id: $issueId) {
      comments(first: $first, filter: {id: {eq: $commentId}}) {
        nodes {
          id
          body
        }
      }
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @remove_label_mutation """
  mutation SymphonyRemoveIssueLabel($issueId: String!, $labelId: String!) {
    issueRemoveLabel(id: $issueId, labelId: $labelId) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec create_comment(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, comment_id, body)
      when is_binary(issue_id) and is_binary(comment_id) and is_binary(body) do
    with {:ok, response} <-
           client_module().graphql(@create_idempotent_comment_mutation, %{
             issueId: issue_id,
             commentId: comment_id,
             body: body
           }),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec fetch_comment(String.t(), String.t()) ::
          {:ok, %{id: String.t(), body: String.t()} | nil} | {:error, term()}
  def fetch_comment(issue_id, comment_id) when is_binary(issue_id) and is_binary(comment_id) do
    with {:ok, response} <-
           client_module().graphql(@comment_read_query, %{
             issueId: issue_id,
             commentId: comment_id,
             first: 1
           }),
         nodes when is_list(nodes) <- get_in(response, ["data", "issue", "comments", "nodes"]) do
      decode_comment(nodes, comment_id)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_read_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec cleanup_issue_labels(term(), [String.t()]) :: :ok | {:error, term()}
  def cleanup_issue_labels(%Issue{id: issue_id} = issue, label_names)
      when is_binary(issue_id) and is_list(label_names) do
    issue
    |> attached_cleanup_labels(label_names)
    |> Enum.reduce_while(:ok, &remove_attached_cleanup_label(issue, issue_id, &1, &2))
  end

  def cleanup_issue_labels(%Issue{}, _label_names), do: {:error, :missing_issue_id}

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp decode_comment([], _comment_id), do: {:ok, nil}

  defp decode_comment([%{"id" => comment_id, "body" => body}], comment_id)
       when is_binary(body) do
    {:ok, %{id: comment_id, body: body}}
  end

  defp decode_comment(_nodes, _comment_id), do: {:error, :comment_read_failed}

  defp attached_cleanup_labels(issue, label_names) do
    label_names
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.filter(&Issue.has_label?(issue, &1))
  end

  defp remove_attached_cleanup_label(issue, issue_id, label_name, :ok) do
    case label_id_for_cleanup(issue, label_name) do
      {:ok, label_id} ->
        case remove_issue_label(issue_id, label_id, label_name) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp label_id_for_cleanup(issue, label_name) do
    case Issue.label_id_for_name(issue, label_name) do
      label_id when is_binary(label_id) and label_id != "" -> {:ok, label_id}
      _ -> {:error, {:missing_label_id, label_name}}
    end
  end

  defp remove_issue_label(issue_id, label_id, label_name) do
    with {:ok, response} <-
           client_module().graphql(@remove_label_mutation, %{issueId: issue_id, labelId: label_id}),
         true <- get_in(response, ["data", "issueRemoveLabel", "success"]) == true do
      :ok
    else
      false -> {:error, {:label_cleanup_failed, label_name, :issue_remove_label_failed}}
      {:error, reason} -> {:error, {:label_cleanup_failed, label_name, reason}}
      _ -> {:error, {:label_cleanup_failed, label_name, :issue_remove_label_failed}}
    end
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
