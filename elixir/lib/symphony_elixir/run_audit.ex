defmodule SymphonyElixir.RunAudit do
  @moduledoc """
  Persists bounded, engine-owned audit events for a single agent run.
  """

  require Logger

  alias SymphonyElixir.Linear.Issue

  @audit_dir ".symphony"
  @jsonl_file "run-audit.jsonl"
  @markdown_file "run-audit.md"
  @first_edit_marker "first-useful-edit"
  @max_preview_chars 160
  @max_summary_bytes 4_194_304
  @phase_names ~w(
    queueing workspace_bootstrap context_loading research planning implementation
    verification review git_pr external_wait handoff run
  )
  @attributions ~w(model tool subprocess external)
  @handoff_events [
    :handoff_publish_started,
    :handoff_comment_result,
    :handoff_transition_reused,
    :handoff_transition_updated,
    :handoff_transition_ambiguous,
    :handoff_transition_result,
    :handoff_publish_result,
    :handoff_publish_rejected,
    :handoff_evidence_pending,
    :handoff_evidence_rejected,
    :handoff_publish_failed,
    :handoff_evidence_validated,
    :handoff_published
  ]
  @handoff_attr_keys [
    :phase,
    :status,
    :thread_id,
    :plan_digest,
    :artifact_digest,
    :evidence_result,
    :comment_id,
    :marker_key,
    :transition_target,
    :transition_result,
    :issue_state,
    :result,
    :retry,
    :ambiguous
  ]

  @type event_name :: atom() | String.t()
  @type handoff_event ::
          :handoff_publish_started
          | :handoff_comment_result
          | :handoff_transition_reused
          | :handoff_transition_updated
          | :handoff_transition_ambiguous
          | :handoff_transition_result
          | :handoff_publish_result
          | :handoff_publish_rejected
          | :handoff_evidence_pending
          | :handoff_evidence_rejected
          | :handoff_publish_failed
          | :handoff_evidence_validated
          | :handoff_published

  @spec paths(Path.t()) :: %{audit_path: Path.t(), audit_events_path: Path.t()}
  def paths(workspace) when is_binary(workspace) do
    %{
      audit_path: markdown_path(workspace),
      audit_events_path: jsonl_path(workspace)
    }
  end

  @spec start(Path.t(), Issue.t(), map()) :: :ok
  def start(workspace, %Issue{} = issue, attrs \\ %{}) when is_binary(workspace) and is_map(attrs) do
    with_audit_guard(workspace, fn ->
      File.mkdir_p!(audit_dir(workspace))
      File.write!(jsonl_path(workspace), "")
      File.rm(first_edit_marker_path(workspace))

      File.write!(
        markdown_path(workspace),
        [
          "# Run Audit\n\n",
          "- issue: `",
          safe_text(issue.identifier || issue.id || "unknown"),
          "`\n",
          "- workspace: `",
          safe_text(workspace),
          "`\n",
          optional_markdown_field("worker_host", Map.get(attrs, :worker_host)),
          "\n## Events\n\n"
        ]
      )

      append(workspace, issue, :run_started, attrs)
    end)
  end

  @spec append(Path.t(), Issue.t(), event_name(), map()) :: :ok
  def append(workspace, %Issue{} = issue, event, attrs \\ %{})
      when is_binary(workspace) and is_map(attrs) do
    with_audit_guard(workspace, fn ->
      File.mkdir_p!(audit_dir(workspace))

      timestamp = DateTime.utc_now()
      normalized_attrs = normalize_attrs(attrs)

      json_event =
        normalized_attrs
        |> Map.merge(%{
          event: to_string(event),
          timestamp: DateTime.to_iso8601(timestamp),
          issue_id: issue.id,
          issue_identifier: issue.identifier
        })
        |> drop_nil_values()

      File.write!(jsonl_path(workspace), Jason.encode!(json_event) <> "\n", [:append])
      File.write!(markdown_path(workspace), markdown_event(timestamp, event, normalized_attrs), [:append])
    end)
  end

  @spec record_phase(
          Path.t(),
          Issue.t(),
          String.t(),
          DateTime.t(),
          DateTime.t(),
          String.t(),
          map()
        ) :: :ok | {:error, term()}
  def record_phase(
        workspace,
        %Issue{} = issue,
        phase,
        %DateTime{} = started_at,
        %DateTime{} = ended_at,
        attribution,
        attrs \\ %{}
      )
      when is_binary(workspace) and is_binary(phase) and is_binary(attribution) and is_map(attrs) do
    case validate_phase_timing(phase, started_at, ended_at, attribution, attrs) do
      {:ok, duration_ms} ->
        timing =
          attrs
          |> Map.merge(%{
            phase: phase,
            status: "completed",
            started_at: started_at,
            ended_at: ended_at,
            duration_ms: duration_ms,
            attribution: attribution,
            budget_overrun_ms: budget_overrun(duration_ms, attr(attrs, :budget_ms))
          })

        append(workspace, issue, :phase_timing, timing)

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_phase_timing(phase, started_at, ended_at, attribution, attrs) do
    duration_ms = DateTime.diff(ended_at, started_at, :millisecond)
    reason = attr(attrs, :reason)

    cond do
      phase not in @phase_names ->
        {:error, {:invalid_phase, phase}}

      attribution not in @attributions ->
        {:error, {:invalid_phase_attribution, attribution}}

      duration_ms < 0 ->
        {:error, :invalid_phase_interval}

      attribution == "external" and (not is_binary(reason) or String.trim(reason) == "") ->
        {:error, :external_wait_reason_required}

      true ->
        {:ok, duration_ms}
    end
  end

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))

  @spec summary(Path.t()) ::
          {:ok,
           %{
             verification_profile: String.t() | nil,
             cache: %{hits: non_neg_integer(), misses: non_neg_integer()},
             slowest_phase: %{phase: String.t(), duration_ms: non_neg_integer()} | nil,
             budget_overruns: [%{phase: String.t(), budget_overrun_ms: pos_integer()}],
             phases: [map()]
           }}
          | {:error, term()}
  def summary(workspace) when is_binary(workspace) do
    with {:ok, events} <- read_events(workspace) do
      phases = Enum.filter(events, &(&1["event"] == "phase_timing"))

      {:ok,
       %{
         verification_profile: latest_value(events, "verification_profile"),
         cache: cache_summary(events),
         slowest_phase: slowest_phase(phases),
         budget_overruns: budget_overruns(phases),
         phases: phases
       }}
    end
  end

  @spec finish(Path.t(), Issue.t()) :: :ok | {:error, term()}
  def finish(workspace, %Issue{} = issue) when is_binary(workspace) do
    with {:ok, run_summary} <- summary(workspace) do
      slowest = run_summary.slowest_phase
      overruns = run_summary.budget_overruns

      append(workspace, issue, :run_summary, %{
        phase: "run",
        status: "completed",
        verification_profile: run_summary.verification_profile,
        cache_hits: run_summary.cache.hits,
        cache_misses: run_summary.cache.misses,
        slowest_phase: slowest && slowest.phase,
        slowest_phase_duration_ms: slowest && slowest.duration_ms,
        budget_overrun_count: length(overruns),
        max_budget_overrun_ms: max_budget_overrun(overruns)
      })
    end
  end

  @spec append_handoff_event(Path.t(), Issue.t(), handoff_event(), map()) :: :ok
  def append_handoff_event(workspace, %Issue{} = issue, event, attrs \\ %{})
      when is_binary(workspace) and is_map(attrs) do
    if event in @handoff_events do
      attrs
      |> Map.take(@handoff_attr_keys)
      |> Map.filter(fn {_key, value} -> scalar?(value) end)
      |> then(&append(workspace, issue, event, &1))
    else
      :ok
    end
  end

  @spec append_codex_update(Path.t(), Issue.t(), map()) ::
          {:ok, %{event_id: String.t(), exit_code: integer(), command: String.t() | nil} | nil}
  def append_codex_update(workspace, %Issue{} = issue, update)
      when is_binary(workspace) and is_map(update) do
    maybe_append_first_useful_edit(workspace, issue, update)

    case codex_audit_attrs(update) do
      nil ->
        {:ok, nil}

      attrs ->
        {attrs, proof} = maybe_attach_command_proof(attrs)
        append(workspace, issue, :codex_update, attrs)
        {:ok, proof}
    end
  end

  def append_codex_update(_workspace, _issue, _update), do: {:ok, nil}

  defp codex_audit_attrs(%{event: :session_started} = update) do
    %{
      phase: "codex_session",
      status: "started",
      session_id: Map.get(update, :session_id),
      thread_id: Map.get(update, :thread_id),
      turn_id: Map.get(update, :turn_id)
    }
  end

  defp codex_audit_attrs(%{event: event, payload: %{"method" => method} = payload})
       when is_binary(method) do
    method_attrs(event, method, payload)
  end

  defp codex_audit_attrs(%{event: event, raw: %{"method" => method} = payload})
       when is_binary(method) do
    method_attrs(event, method, payload)
  end

  defp codex_audit_attrs(%{event: event, raw: raw}) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{"method" => method} = payload} when is_binary(method) ->
        method_attrs(event, method, payload)

      _ ->
        nil
    end
  end

  defp codex_audit_attrs(_update), do: nil

  defp method_attrs(_event, "turn/completed", payload) do
    %{
      phase: "codex_turn",
      status: "completed",
      method: "turn/completed",
      detail: turn_status(payload)
    }
  end

  defp method_attrs(_event, "turn/failed", payload) do
    %{
      phase: "codex_turn",
      status: "failed",
      method: "turn/failed",
      detail: preview(payload)
    }
  end

  defp method_attrs(_event, "turn/cancelled", payload) do
    %{
      phase: "codex_turn",
      status: "cancelled",
      method: "turn/cancelled",
      detail: preview(payload)
    }
  end

  defp method_attrs(
         _event,
         "item/completed",
         %{
           "params" => %{
             "item" =>
               %{
                 "type" => "commandExecution",
                 "exitCode" => exit_code
               } = item
           }
         }
       )
       when is_integer(exit_code) do
    %{
      phase: "command",
      status: "completed",
      method: "item/completed",
      command: Map.get(item, "command"),
      exit_code: exit_code
    }
  end

  defp method_attrs(_event, "codex/event/exec_command_begin", payload) do
    %{
      phase: "command",
      status: "started",
      method: "codex/event/exec_command_begin",
      command: command_from_payload(payload)
    }
  end

  defp method_attrs(_event, "codex/event/exec_command_end", payload) do
    %{
      phase: "command",
      status: "completed",
      method: "codex/event/exec_command_end",
      exit_code: exit_code_from_payload(payload)
    }
  end

  defp method_attrs(_event, "codex/event/exec_command_output_delta", payload) do
    case output_delta_from_payload(payload) do
      detail when is_binary(detail) ->
        detail = preview(detail)

        if important_command_output?(detail) do
          %{
            phase: "command",
            status: "output",
            method: "codex/event/exec_command_output_delta",
            detail: detail
          }
        end

      _ ->
        nil
    end
  end

  defp method_attrs(_event, _method, _payload), do: nil

  defp maybe_attach_command_proof(
         %{
           phase: "command",
           status: "completed",
           method: method,
           exit_code: exit_code
         } = attrs
       )
       when method in ["codex/event/exec_command_end", "item/completed"] and is_integer(exit_code) do
    event_id = "proof-" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
    {Map.put(attrs, :event_id, event_id), %{event_id: event_id, exit_code: exit_code, command: Map.get(attrs, :command)}}
  end

  defp maybe_attach_command_proof(attrs), do: {attrs, nil}

  defp maybe_append_first_useful_edit(workspace, issue, %{payload: %{"method" => method} = payload})
       when method in ["item/started", "item/completed"] do
    if get_in(payload, ["params", "item", "type"]) == "fileChange" do
      case File.write(first_edit_marker_path(workspace), "", [:write, :exclusive]) do
        :ok ->
          append(workspace, issue, :first_useful_edit, %{
            phase: "implementation",
            status: if(method == "item/completed", do: "completed", else: "started"),
            method: method
          })

        {:error, :eexist} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to record first useful edit marker: #{inspect(reason)}")
          :ok
      end
    end
  end

  defp maybe_append_first_useful_edit(_workspace, _issue, _update), do: :ok

  defp command_from_payload(payload) do
    get_in(payload, ["params", "msg", "command"]) ||
      get_in(payload, ["params", "msg", "parsed_cmd"]) ||
      get_in(payload, ["params", "command"]) ||
      get_in(payload, ["params", "parsedCmd"])
  end

  defp exit_code_from_payload(payload) do
    get_in(payload, ["params", "msg", "exit_code"]) ||
      get_in(payload, ["params", "msg", "exitCode"]) ||
      get_in(payload, ["params", "exit_code"]) ||
      get_in(payload, ["params", "exitCode"])
  end

  defp output_delta_from_payload(payload) do
    get_in(payload, ["params", "msg", "payload", "outputDelta"]) ||
      get_in(payload, ["params", "msg", "outputDelta"]) ||
      get_in(payload, ["params", "outputDelta"])
  end

  defp important_command_output?(detail) when is_binary(detail) do
    String.match?(
      detail,
      ~r/\b(error|fail(?:ed|ure|ures)?|fatal|panic|exception|warn(?:ing)?|tests?|passed|coverage|skipped)\b/i
    )
  end

  defp turn_status(payload) do
    get_in(payload, ["params", "turn", "status"]) || "completed"
  end

  defp normalize_attrs(attrs) do
    attrs
    |> Enum.map(fn {key, value} -> {key, normalize_value(value)} end)
    |> Map.new()
    |> drop_nil_values()
  end

  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_value(value) when is_binary(value), do: preview(value)
  defp normalize_value(value) when is_boolean(value), do: value
  defp normalize_value(value) when is_atom(value), do: to_string(value)
  defp normalize_value(value) when is_integer(value), do: value
  defp normalize_value(value) when is_float(value), do: value
  defp normalize_value(nil), do: nil
  defp normalize_value(value), do: preview(value)

  defp budget_overrun(duration_ms, budget_ms)
       when is_integer(budget_ms) and budget_ms >= 0 and duration_ms > budget_ms,
       do: duration_ms - budget_ms

  defp budget_overrun(_duration_ms, _budget_ms), do: nil

  defp read_events(workspace) do
    path = jsonl_path(workspace)

    case File.read(path) do
      {:ok, payload} when byte_size(payload) <= @max_summary_bytes ->
        decode_events(payload)

      {:ok, _payload} ->
        {:error, :run_audit_too_large}

      {:error, reason} ->
        {:error, {:run_audit_read_failed, reason}}
    end
  end

  defp decode_events(payload) do
    payload
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, events} ->
      case Jason.decode(line) do
        {:ok, event} when is_map(event) -> {:cont, {:ok, [event | events]}}
        _invalid -> {:halt, {:error, :invalid_run_audit_event}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, _reason} = error -> error
    end
  end

  defp latest_value(events, key) do
    events
    |> Enum.reverse()
    |> Enum.find_value(&Map.get(&1, key))
  end

  defp cache_summary(events) do
    Enum.reduce(events, %{hits: 0, misses: 0}, fn
      %{"cache_status" => "hit"}, counts -> Map.update!(counts, :hits, &(&1 + 1))
      %{"cache_status" => "miss"}, counts -> Map.update!(counts, :misses, &(&1 + 1))
      _event, counts -> counts
    end)
  end

  defp slowest_phase([]), do: nil

  defp slowest_phase(phases) do
    phases
    |> Enum.max_by(& &1["duration_ms"])
    |> then(&%{phase: &1["phase"], duration_ms: &1["duration_ms"]})
  end

  defp budget_overruns(phases) do
    phases
    |> Enum.flat_map(fn phase ->
      case phase["budget_overrun_ms"] do
        overrun when is_integer(overrun) and overrun > 0 ->
          [%{phase: phase["phase"], budget_overrun_ms: overrun}]

        _ ->
          []
      end
    end)
  end

  defp max_budget_overrun([]), do: 0
  defp max_budget_overrun(overruns), do: overruns |> Enum.map(& &1.budget_overrun_ms) |> Enum.max()

  defp scalar?(value) do
    is_binary(value) or is_atom(value) or is_integer(value) or is_float(value) or
      is_boolean(value) or is_nil(value)
  end

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp markdown_event(timestamp, event, attrs) do
    detail =
      attrs
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{safe_text(value)}" end)

    suffix = if detail == "", do: "", else: " — #{detail}"

    ["- ", DateTime.to_iso8601(timestamp), " `", to_string(event), "`", suffix, "\n"]
  end

  defp optional_markdown_field(_label, nil), do: ""
  defp optional_markdown_field(label, value), do: ["- ", label, ": `", safe_text(value), "`\n"]

  defp preview(value) when is_binary(value) do
    value
    |> String.replace("\n", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @max_preview_chars)
  end

  defp preview(value), do: value |> inspect(limit: 10) |> preview()

  defp safe_text(value), do: value |> to_string() |> String.replace("`", "'")

  defp audit_dir(workspace), do: Path.join(workspace, @audit_dir)
  defp jsonl_path(workspace), do: Path.join(audit_dir(workspace), @jsonl_file)
  defp markdown_path(workspace), do: Path.join(audit_dir(workspace), @markdown_file)
  defp first_edit_marker_path(workspace), do: Path.join(audit_dir(workspace), @first_edit_marker)

  defp with_audit_guard(workspace, fun) when is_function(fun, 0) do
    fun.()
    :ok
  rescue
    error ->
      Logger.warning("Failed to write run audit workspace=#{workspace}: #{Exception.message(error)}")
      :ok
  end
end
