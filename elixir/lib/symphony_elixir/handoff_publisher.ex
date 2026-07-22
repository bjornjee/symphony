defmodule SymphonyElixir.HandoffPublisher do
  @moduledoc """
  Publishes one deterministic, read-verified tracker handoff before state transition.
  """

  import Bitwise
  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.{Issue, TaskContract}
  alias SymphonyElixir.Tracker

  @marker_prefix "symphony-agent-handoff:v1"

  @type evidence :: %{
          required(:artifact_digest) => String.t(),
          required(:criteria) => [%{required(:criterion_id) => String.t(), required(:proof_event_id) => String.t()}],
          required(:pull_request_url) => String.t()
        }
  @type event_sink :: (atom(), map() -> term())

  @spec publish(Issue.t(), TaskContract.t(), evidence(), keyword()) ::
          {:ok, %{comment_id: String.t(), issue_state: String.t()}} | {:error, term()}
  def publish(%Issue{} = issue, %TaskContract{} = contract, evidence, opts \\ [])
      when is_map(evidence) and is_list(opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    event_sink = Keyword.get(opts, :event_sink)

    handoff_state =
      Keyword.get_lazy(opts, :handoff_state, fn -> Config.settings!().tracker.handoff_state end)

    comment_id = comment_id(issue, contract, evidence)
    body = render(issue, contract, evidence)
    event_context = event_context(issue, contract, evidence, comment_id, handoff_state, opts)

    emit_event(event_sink, :handoff_publish_started, event_context, %{
      status: "started",
      evidence_result: "accepted",
      result: "started",
      retry: false,
      ambiguous: false
    })

    result =
      with :ok <- ensure_comment(tracker, issue.id, comment_id, body, event_sink, event_context),
           :ok <-
             transition_issue(
               tracker,
               issue.id,
               issue.state,
               handoff_state,
               event_sink,
               event_context
             ) do
        Logger.info("Linear handoff state transitioned issue_id=#{issue.id} issue_identifier=#{issue.identifier} handoff_comment_id=#{comment_id} issue_state=#{handoff_state}")

        {:ok, %{comment_id: comment_id, issue_state: handoff_state}}
      end

    emit_publish_result(event_sink, event_context, result)
    result
  end

  @spec comment_id(Issue.t(), TaskContract.t(), evidence()) :: String.t()
  def comment_id(%Issue{id: issue_id}, %TaskContract{digest: plan_digest}, %{artifact_digest: artifact_digest}) do
    digest = handoff_digest(issue_id, plan_digest, artifact_digest)
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> = digest
    c = (c &&& 0x0FFF) ||| 0x4000
    d = (d &&& 0x3FFF) ||| 0x8000

    [
      hex(a, 8),
      "-",
      hex(b, 4),
      "-",
      hex(c, 4),
      "-",
      hex(d, 4),
      "-",
      hex(e, 12)
    ]
    |> IO.iodata_to_binary()
  end

  @spec render(Issue.t(), TaskContract.t(), evidence()) :: String.t()
  def render(%Issue{} = issue, %TaskContract{} = contract, evidence) when is_map(evidence) do
    validated_criterion_ids = MapSet.new(evidence.criteria, & &1.criterion_id)

    criterion_lines =
      Enum.map_join(contract.acceptance_criteria, "\n", fn criterion ->
        true = MapSet.member?(validated_criterion_ids, criterion.id)
        "- ✅ #{inline_text(criterion.text)} — passed with an engine-owned proof receipt"
      end)

    marker_key = marker_key(issue, contract, evidence)

    """
    ## Agent Handoff

    PR: #{evidence.pull_request_url}

    ### Acceptance criteria

    #{criterion_lines}

    Verification: #{length(contract.acceptance_criteria)} acceptance criteria passed with engine-owned proof receipts.

    Human action: Review and approve the pull request.

    <!-- #{@marker_prefix} key=#{marker_key} -->
    """
    |> String.trim()
  end

  defp ensure_comment(tracker, issue_id, comment_id, body, event_sink, event_context) do
    case tracker.fetch_comment(issue_id, comment_id) do
      {:ok, nil} ->
        create_and_verify_comment(tracker, issue_id, comment_id, body, event_sink, event_context)

      {:ok, %{id: ^comment_id, body: ^body}} ->
        emit_comment_result(event_sink, event_context, "reused", "none", nil, "completed")
        :ok

      {:ok, %{id: ^comment_id}} ->
        emit_comment_result(event_sink, event_context, "collision", "collision", "comment_collision", "failed")
        {:error, {:handoff_comment_collision, comment_id}}

      {:error, reason} ->
        emit_comment_result(event_sink, event_context, "read_failed", "readback_failed", "comment_read_failed", "failed")
        {:error, {:handoff_comment_read_failed, reason}}

      other ->
        emit_comment_result(event_sink, event_context, "read_failed", "readback_failed", "comment_read_failed", "failed")
        {:error, {:handoff_comment_read_failed, other}}
    end
  end

  defp create_and_verify_comment(tracker, issue_id, comment_id, body, event_sink, event_context) do
    create_result = tracker.create_comment(issue_id, comment_id, body)
    create_ambiguity = if create_result == :ok, do: "none", else: "create_unknown"

    case tracker.fetch_comment(issue_id, comment_id) do
      {:ok, %{id: ^comment_id, body: ^body}} ->
        emit_comment_result(event_sink, event_context, "created", create_ambiguity, nil, "completed")
        :ok

      {:ok, %{id: ^comment_id}} ->
        emit_comment_result(event_sink, event_context, "collision", "collision", "comment_collision", "failed")
        {:error, {:handoff_comment_collision, comment_id}}

      {:ok, nil} ->
        emit_comment_result(event_sink, event_context, "unverified", create_ambiguity, "comment_unverified", "failed")
        {:error, {:handoff_comment_unverified, comment_id, create_result}}

      {:error, reason} ->
        emit_comment_result(event_sink, event_context, "read_failed", "readback_failed", "comment_read_failed", "failed")

        {:error, {:handoff_comment_read_failed, reason, create_result}}

      other ->
        emit_comment_result(event_sink, event_context, "read_failed", "readback_failed", "comment_read_failed", "failed")
        {:error, {:handoff_comment_read_failed, other, create_result}}
    end
  end

  defp transition_issue(
         tracker,
         issue_id,
         expected_source_state,
         handoff_state,
         event_sink,
         event_context
       ) do
    case fetch_issue_state(tracker, issue_id) do
      {:ok, current_state} ->
        cond do
          same_state?(current_state, handoff_state) ->
            emit_transition(event_sink, :handoff_transition_reused, event_context, %{
              status: "completed",
              transition_result: "reused",
              result: "completed",
              retry: false,
              ambiguous: false
            })

            emit_transition_result(event_sink, event_context, "completed", "reused", current_state, "none", nil)
            :ok

          same_state?(current_state, expected_source_state) ->
            update_and_verify_transition(tracker, issue_id, handoff_state, event_sink, event_context)

          true ->
            emit_transition_result(event_sink, event_context, "failed", "mismatch", current_state, "none", nil)

            {:error, {:handoff_state_source_mismatch, expected_source_state, current_state, handoff_state}}
        end

      {:error, reason} ->
        emit_transition_result(event_sink, event_context, "failed", "read_failed", nil, "readback_failed", "state_read_failed")
        {:error, {:handoff_state_read_failed, reason}}
    end
  end

  defp update_and_verify_transition(tracker, issue_id, handoff_state, event_sink, event_context) do
    update_result = tracker.update_issue_state(issue_id, handoff_state)

    if update_result != :ok do
      emit_transition(event_sink, :handoff_transition_ambiguous, event_context, %{
        status: "retrying",
        transition_result: "ambiguous",
        result: "pending",
        retry: true,
        ambiguous: true
      })
    end

    verify_transition_readback(
      tracker,
      issue_id,
      handoff_state,
      update_result,
      event_sink,
      event_context
    )
  end

  defp verify_transition_readback(
         tracker,
         issue_id,
         handoff_state,
         update_result,
         event_sink,
         event_context
       ) do
    case fetch_issue_state(tracker, issue_id) do
      {:ok, current_state} ->
        transition_readback_result(
          current_state,
          handoff_state,
          update_result,
          event_sink,
          event_context
        )

      {:error, reason} ->
        emit_transition_result(event_sink, event_context, "failed", "read_failed", nil, "readback_failed", "state_read_failed")
        {:error, {:handoff_state_transition_read_failed, handoff_state, reason}}
    end
  end

  defp transition_readback_result(
         current_state,
         handoff_state,
         update_result,
         event_sink,
         event_context
       ) do
    if same_state?(current_state, handoff_state) do
      if update_result == :ok do
        emit_transition(event_sink, :handoff_transition_updated, event_context, %{
          status: "completed",
          transition_result: "updated",
          result: "completed",
          retry: false,
          ambiguous: false
        })

        emit_transition_result(event_sink, event_context, "completed", "updated", current_state, "none", nil)
      else
        emit_transition_result(
          event_sink,
          event_context,
          "completed",
          "reconciled",
          current_state,
          "state_transition_failed",
          nil
        )
      end

      :ok
    else
      emit_transition_result(
        event_sink,
        event_context,
        "failed",
        "mismatch",
        current_state,
        if(update_result == :ok, do: "none", else: "state_transition_failed"),
        "state_transition_mismatch"
      )

      transition_mismatch_error(update_result, handoff_state, current_state)
    end
  end

  defp transition_mismatch_error(:ok, handoff_state, current_state) do
    {:error, {:handoff_state_transition_unverified, handoff_state, current_state}}
  end

  defp transition_mismatch_error({:error, reason}, handoff_state, _current_state) do
    {:error, {:handoff_state_transition_failed, handoff_state, reason}}
  end

  defp transition_mismatch_error(other, handoff_state, _current_state) do
    {:error, {:handoff_state_transition_failed, handoff_state, other}}
  end

  defp fetch_issue_state(tracker, issue_id) do
    case tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, issues} when is_list(issues) ->
        case Enum.find(issues, &match?(%Issue{id: ^issue_id}, &1)) do
          %Issue{state: state} when is_binary(state) -> {:ok, state}
          nil -> {:error, :issue_missing}
          _other -> {:error, :invalid_issue_state}
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp event_context(issue, contract, evidence, comment_id, handoff_state, opts) do
    %{
      phase: "handoff",
      thread_id: Keyword.get(opts, :thread_id),
      plan_digest: contract.digest,
      artifact_digest: evidence.artifact_digest,
      comment_id: comment_id,
      marker_key: marker_key(issue, contract, evidence),
      transition_target: handoff_state
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp emit_comment_result(event_sink, event_context, _result, ambiguity, retry_reason, status) do
    emit_event(event_sink, :handoff_comment_result, event_context, %{
      status: status,
      result: if(status == "completed", do: "completed", else: "failed"),
      retry: not is_nil(retry_reason),
      ambiguous: ambiguity != "none"
    })
  end

  defp emit_transition(event_sink, event, event_context, attrs) do
    emit_event(event_sink, event, event_context, attrs)
  end

  defp emit_transition_result(
         event_sink,
         event_context,
         status,
         transition_result,
         _issue_state,
         ambiguity,
         retry_reason
       ) do
    emit_transition(event_sink, :handoff_transition_result, event_context, %{
      status: status,
      transition_result: transition_result,
      result: if(status == "completed", do: "completed", else: "failed"),
      retry: not is_nil(retry_reason),
      ambiguous: ambiguity != "none"
    })
  end

  defp emit_publish_result(event_sink, event_context, {:ok, _publication}) do
    emit_event(event_sink, :handoff_publish_result, event_context, %{
      status: "completed",
      evidence_result: "published",
      result: "completed",
      retry: false,
      ambiguous: false
    })
  end

  defp emit_publish_result(event_sink, event_context, {:error, reason}) do
    emit_event(event_sink, :handoff_publish_result, event_context, %{
      status: "failed",
      evidence_result: "publish_failed",
      result: "failed",
      retry: true,
      ambiguous: ambiguity(reason) != "none"
    })
  end

  defp emit_event(event_sink, event, event_context, attrs) when is_function(event_sink, 2) do
    event_sink.(event, Map.merge(event_context, attrs))
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp emit_event(_event_sink, _event, _event_context, _attrs), do: :ok

  defp ambiguity({:handoff_comment_collision, _comment_id}), do: "collision"
  defp ambiguity({:handoff_comment_unverified, _comment_id, _result}), do: "create_unknown"
  defp ambiguity({:handoff_comment_read_failed, _reason}), do: "readback_failed"
  defp ambiguity({:handoff_comment_read_failed, _reason, _result}), do: "readback_failed"
  defp ambiguity({reason, _rest}) when reason in [:handoff_state_read_failed], do: "readback_failed"

  defp ambiguity({reason, _one, _two})
       when reason in [
              :handoff_state_transition_failed,
              :handoff_state_transition_read_failed,
              :handoff_state_transition_unverified
            ],
       do: "state_transition_failed"

  defp ambiguity(_reason), do: "none"

  defp same_state?(left, right) when is_binary(left) and is_binary(right) do
    String.downcase(String.trim(left)) == String.downcase(String.trim(right))
  end

  defp marker_key(%Issue{id: issue_id}, %TaskContract{digest: plan_digest}, %{artifact_digest: artifact_digest}) do
    issue_id
    |> handoff_digest(plan_digest, artifact_digest)
    |> Base.encode16(case: :lower)
  end

  defp handoff_digest(issue_id, plan_digest, artifact_digest) do
    :crypto.hash(:sha256, [@marker_prefix, 0, issue_id, 0, plan_digest, 0, artifact_digest])
  end

  defp inline_text(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> then(&Regex.replace(~r/([\\`*_{}\[\]()#|])/u, &1, fn match -> "\\" <> match end))
  end

  defp hex(value, width) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(width, "0")
  end
end
