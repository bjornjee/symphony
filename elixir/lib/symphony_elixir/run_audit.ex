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
  @attempt_manifest "attempts.json"
  @active_attempt_marker ".active"
  @active_attempt_guard_timeout_ms 5_000
  @retained_central_attempts 5
  @max_preview_chars 160
  @max_summary_bytes 4_194_304
  @compact_tail_events 50
  @phase_names ~w(
    queueing workspace_bootstrap context_loading research planning implementation
    verification review git_pr external_wait handoff run
  )
  @phase_budgets_ms %{
    "queueing" => 30_000,
    "workspace_bootstrap" => 60_000,
    "context_loading" => 60_000,
    "research" => 60_000,
    "planning" => 240_000,
    "implementation" => 240_000,
    "verification" => 300_000,
    "review" => 120_000,
    "git_pr" => 120_000,
    "external_wait" => 120_000,
    "handoff" => 120_000,
    "run" => 600_000
  }
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
  @type time_point :: %{utc: DateTime.t(), monotonic_ms: integer()}
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

  @spec paths(Path.t(), Issue.t()) :: %{audit_path: Path.t(), audit_events_path: Path.t()}
  def paths(workspace, %Issue{} = issue) when is_binary(workspace) do
    directory = central_audit_dir(workspace, issue)

    %{
      audit_path: Path.join(directory, @markdown_file),
      audit_events_path: Path.join(directory, @jsonl_file)
    }
  end

  @spec now() :: time_point()
  def now do
    %{utc: DateTime.utc_now(), monotonic_ms: System.monotonic_time(:millisecond)}
  end

  @spec start(Path.t(), Issue.t(), map()) :: :ok
  def start(workspace, %Issue{} = issue, attrs \\ %{}) when is_binary(workspace) and is_map(attrs) do
    {run_id, audit_attrs} =
      case bind_central_audit_attempt(workspace, issue) do
        {:ok, run_id} ->
          {run_id, %{}}

        {:error, reason} ->
          run_id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
          fallback = fallback_audit_dir(workspace, issue, run_id)
          Process.put(central_audit_context_key(workspace, issue), fallback)

          Logger.warning("Central run-audit registration failed; using fallback workspace=#{workspace} reason=#{inspect(reason)}")

          {run_id, %{audit_sink: "fallback", audit_sink_error: inspect(reason)}}
      end

    attrs = attrs |> Map.merge(audit_attrs) |> Map.put(:run_id, run_id)

    Enum.each(audit_targets(workspace, issue), fn directory ->
      with_audit_guard(workspace, fn ->
        File.mkdir_p!(directory)
        File.write!(Path.join(directory, @jsonl_file), "")
        File.rm(Path.join(directory, @first_edit_marker))

        File.write!(
          Path.join(directory, @markdown_file),
          markdown_header(workspace, issue, attrs)
        )
      end)
    end)

    append(workspace, issue, :run_started, attrs)
  end

  @spec append(Path.t(), Issue.t(), event_name(), map()) :: :ok
  def append(workspace, %Issue{} = issue, event, attrs \\ %{})
      when is_binary(workspace) and is_map(attrs) do
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

    Enum.each(audit_targets(workspace, issue), fn directory ->
      with_audit_guard(workspace, fn ->
        File.mkdir_p!(directory)
        append_json_event(Path.join(directory, @jsonl_file), json_event)

        append_markdown_event(
          Path.join(directory, @markdown_file),
          markdown_event(timestamp, event, normalized_attrs)
        )
      end)
    end)
  end

  @spec record_phase(
          Path.t(),
          Issue.t(),
          String.t(),
          time_point(),
          time_point(),
          String.t(),
          map()
        ) :: :ok | {:error, term()}
  def record_phase(
        workspace,
        %Issue{} = issue,
        phase,
        %{utc: %DateTime{} = started_at, monotonic_ms: started_monotonic_ms},
        %{utc: %DateTime{} = ended_at, monotonic_ms: ended_monotonic_ms},
        attribution,
        attrs \\ %{}
      )
      when is_binary(workspace) and is_binary(phase) and is_integer(started_monotonic_ms) and
             is_integer(ended_monotonic_ms) and is_binary(attribution) and is_map(attrs) do
    case validate_phase_timing(
           phase,
           started_monotonic_ms,
           ended_monotonic_ms,
           attribution,
           attrs
         ) do
      {:ok, duration_ms} ->
        budget_ms = attr(attrs, :budget_ms) || Map.fetch!(@phase_budgets_ms, phase)

        timing =
          attrs
          |> Map.merge(%{
            phase: phase,
            status: "completed",
            started_at: started_at,
            ended_at: ended_at,
            duration_ms: duration_ms,
            attribution: attribution,
            budget_ms: budget_ms,
            budget_overrun_ms: budget_overrun(duration_ms, budget_ms)
          })

        append(workspace, issue, :phase_timing, timing)

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_phase_timing(phase, started_at_ms, ended_at_ms, attribution, attrs) do
    duration_ms = ended_at_ms - started_at_ms
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
             cache: %{
               context: %{hits: non_neg_integer(), misses: non_neg_integer()},
               proof: %{hits: non_neg_integer(), misses: non_neg_integer()}
             },
             slowest_phase: %{phase: String.t(), duration_ms: non_neg_integer()} | nil,
             budget_overruns: [%{phase: String.t(), budget_overrun_ms: pos_integer()}],
             phases: [map()]
           }}
          | {:error, term()}
  def summary(workspace) when is_binary(workspace) do
    summary_path(jsonl_path(workspace))
  end

  @spec summary_path(Path.t()) :: {:ok, map()} | {:error, term()}
  def summary_path(path) when is_binary(path) do
    with {:ok, events} <- read_events_path(path) do
      {:ok, summarize_events(events)}
    end
  end

  @spec finish(Path.t(), Issue.t()) :: :ok | {:error, term()}
  def finish(workspace, %Issue{} = issue) when is_binary(workspace) do
    summary_result =
      case finish_summary(workspace, issue) do
        {:ok, run_summary} ->
          append_run_summary(workspace, issue, run_summary)
          :ok

        {:error, _reason} = error ->
          error
      end

    completion_result = complete_central_audit_attempt(workspace, issue)
    finish_result(workspace, summary_result, completion_result)
  end

  defp finish_summary(workspace, issue) do
    central_path = paths(workspace, issue).audit_events_path

    case summary_path(central_path) do
      {:ok, _summary} = result ->
        result

      {:error, _reason} = central_error ->
        local_path = jsonl_path(workspace)
        if local_path == central_path, do: central_error, else: summary_path(local_path)
    end
  end

  defp append_run_summary(workspace, issue, run_summary) do
    slowest = run_summary.slowest_phase
    overruns = run_summary.budget_overruns

    append(workspace, issue, :run_summary, %{
      phase: "run",
      status: "completed",
      verification_profile: run_summary.verification_profile,
      context_cache_hits: run_summary.cache.context.hits,
      context_cache_misses: run_summary.cache.context.misses,
      proof_cache_hits: run_summary.cache.proof.hits,
      proof_cache_misses: run_summary.cache.proof.misses,
      slowest_phase: slowest && slowest.phase,
      slowest_phase_duration_ms: slowest && slowest.duration_ms,
      budget_overrun_count: length(overruns),
      max_budget_overrun_ms: max_budget_overrun(overruns)
    })
  end

  defp finish_result(_workspace, :ok, :ok), do: :ok

  defp finish_result(workspace, summary_result, completion_result) do
    Logger.warning("Run-audit finalization incomplete workspace=#{workspace} summary=#{inspect(summary_result)} completion=#{inspect(completion_result)}")

    {:error, {:run_audit_finalization_incomplete, summary_result, completion_result}}
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

  defp maybe_append_first_useful_edit(
         workspace,
         issue,
         %{payload: %{"method" => "item/completed"} = payload}
       ) do
    if get_in(payload, ["params", "item", "type"]) == "fileChange" do
      case File.write(first_edit_marker_path(workspace, issue), "", [:write, :exclusive]) do
        :ok ->
          append(workspace, issue, :first_useful_edit, %{
            phase: "implementation",
            status: "completed",
            method: "item/completed"
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

  defp read_events_path(path) do
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

  defp summarize_events(events) do
    {compacted, current} = split_compacted_summary(events)

    phases =
      compacted
      |> compacted_phases()
      |> Kernel.++(Enum.filter(current, &(&1["event"] == "phase_timing")))
      |> aggregate_phase_slices()

    cache = merge_cache(compacted_cache(compacted), cache_summary(current))

    %{
      verification_profile:
        latest_value(current, "verification_profile") ||
          compacted_value(compacted, "verification_profile"),
      cache: cache,
      slowest_phase: slowest_phase(phases),
      budget_overruns: budget_overruns(phases),
      phases: phases
    }
  end

  defp split_compacted_summary(events) do
    index =
      events
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn
        {%{"event" => "run_summary", "compacted" => true}, index} -> index
        _event -> nil
      end)

    if is_integer(index) do
      {Enum.at(events, index), Enum.drop(events, index + 1)}
    else
      {nil, events}
    end
  end

  defp compacted_value(nil, _key), do: nil
  defp compacted_value(summary, key), do: summary[key]

  defp compacted_phases(%{"phases" => phases}) when is_list(phases), do: phases
  defp compacted_phases(_summary), do: []

  defp compacted_cache(nil), do: empty_cache()

  defp compacted_cache(summary) do
    %{
      context: %{
        hits: non_negative_integer(summary["context_cache_hits"]),
        misses: non_negative_integer(summary["context_cache_misses"])
      },
      proof: %{
        hits: non_negative_integer(summary["proof_cache_hits"]),
        misses: non_negative_integer(summary["proof_cache_misses"])
      }
    }
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  defp merge_cache(left, right) do
    %{
      context: %{
        hits: left.context.hits + right.context.hits,
        misses: left.context.misses + right.context.misses
      },
      proof: %{
        hits: left.proof.hits + right.proof.hits,
        misses: left.proof.misses + right.proof.misses
      }
    }
  end

  defp cache_summary(events) do
    Enum.reduce(events, empty_cache(), fn
      %{"cache" => cache, "cache_status" => status}, counts
      when cache in ["context", "execution_context"] and status in ["hit", "miss"] ->
        update_in(counts, [:context, cache_count_key(status)], &(&1 + 1))

      %{"cache" => "proof", "cache_status" => status}, counts
      when status in ["hit", "miss"] ->
        update_in(counts, [:proof, cache_count_key(status)], &(&1 + 1))

      _event, counts ->
        counts
    end)
  end

  defp empty_cache do
    %{
      context: %{hits: 0, misses: 0},
      proof: %{hits: 0, misses: 0}
    }
  end

  defp cache_count_key("hit"), do: :hits
  defp cache_count_key("miss"), do: :misses

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
    |> Enum.sort_by(& &1.phase)
  end

  defp aggregate_phase_slices(phases) do
    phases
    |> Enum.filter(&(is_binary(&1["phase"]) and is_integer(&1["duration_ms"])))
    |> Enum.group_by(& &1["phase"])
    |> Enum.map(fn {_phase, values} -> aggregate_phase(values) end)
    |> Enum.sort_by(& &1["phase"])
  end

  defp aggregate_phase([first | _] = values) do
    duration_ms = Enum.sum(Enum.map(values, & &1["duration_ms"]))

    budget_ms =
      values
      |> Enum.map(& &1["budget_ms"])
      |> Enum.filter(&(is_integer(&1) and &1 >= 0))
      |> Enum.min(fn -> nil end)

    recorded_overrun_ms =
      values
      |> Enum.map(& &1["budget_overrun_ms"])
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
      |> Enum.max(fn -> nil end)

    attribution_ms =
      Enum.reduce(values, %{}, fn value, totals ->
        value
        |> phase_attribution_ms()
        |> Map.merge(totals, fn _attribution, duration, total -> duration + total end)
      end)

    slice_count = Enum.sum(Enum.map(values, &non_negative_integer(&1["slice_count"] || 1)))

    first
    |> Map.drop(["attribution", "started_at", "ended_at", "status", "timestamp"])
    |> Map.put("event", "phase_timing_summary")
    |> Map.put("duration_ms", duration_ms)
    |> Map.put("budget_ms", budget_ms)
    |> Map.put("attribution_ms", attribution_ms)
    |> Map.put("slice_count", slice_count)
    |> Map.put(
      "budget_overrun_ms",
      if(
        is_integer(budget_ms) and duration_ms > budget_ms,
        do: duration_ms - budget_ms,
        else: recorded_overrun_ms
      )
    )
  end

  defp phase_attribution_ms(%{"attribution_ms" => totals}) when is_map(totals) do
    Map.filter(totals, fn {attribution, duration} ->
      attribution in @attributions and is_integer(duration) and duration >= 0
    end)
  end

  defp phase_attribution_ms(%{"attribution" => attribution, "duration_ms" => duration})
       when attribution in @attributions and is_integer(duration) and duration >= 0,
       do: %{attribution => duration}

  defp phase_attribution_ms(_phase), do: %{}

  defp compact_phases(phases), do: aggregate_phase_slices(phases)

  defp max_budget_overrun([]), do: 0
  defp max_budget_overrun(overruns), do: overruns |> Enum.map(& &1.budget_overrun_ms) |> Enum.max()

  defp append_json_event(path, event) do
    line = Jason.encode!(event) <> "\n"
    current_size = file_size(path)

    if current_size + byte_size(line) <= @max_summary_bytes do
      File.write!(path, line, [:append])
    else
      compact_json_events(path, event)
    end
  end

  defp compact_json_events(path, event) do
    existing =
      case File.read(path) do
        {:ok, payload} ->
          case decode_events(payload) do
            {:ok, events} -> events
            {:error, reason} -> raise "cannot compact invalid run audit: #{inspect(reason)}"
          end

        {:error, :enoent} ->
          []

        {:error, reason} ->
          raise File.Error, reason: reason, action: "read", path: path
      end

    events = existing ++ [event]
    summary = compacted_summary_event(events)
    run_started = Enum.find(events, &(&1["event"] == "run_started"))
    first_useful_edit = Enum.find(events, &(&1["event"] == "first_useful_edit"))

    tail =
      events
      |> Enum.reject(&summary_owned_event?/1)
      |> Enum.take(-@compact_tail_events)

    fixed = [run_started, first_useful_edit, summary] |> Enum.reject(&is_nil/1) |> Enum.uniq()
    remaining_bytes = max(@max_summary_bytes - byte_size(encode_events(fixed)), 0)
    payload = encode_events(fixed ++ bounded_event_tail(tail, remaining_bytes))

    File.write!(path, payload)
  end

  defp compacted_summary_event(events) do
    summary = summarize_events(events)

    %{
      "event" => "run_summary",
      "compacted" => true,
      "timestamp" => latest_value(events, "timestamp"),
      "verification_profile" => summary.verification_profile,
      "context_cache_hits" => summary.cache.context.hits,
      "context_cache_misses" => summary.cache.context.misses,
      "proof_cache_hits" => summary.cache.proof.hits,
      "proof_cache_misses" => summary.cache.proof.misses,
      "slowest_phase" => summary.slowest_phase && summary.slowest_phase.phase,
      "slowest_phase_duration_ms" => summary.slowest_phase && summary.slowest_phase.duration_ms,
      "budget_overruns" => summary.budget_overruns,
      "phases" => compact_phases(summary.phases)
    }
    |> drop_nil_values()
  end

  defp summary_owned_event?(%{"event" => event}) do
    event in [
      "phase_timing",
      "verification_profile_selected",
      "execution_plan_approved",
      "context_cache_result",
      "proof_cache_result",
      "run_summary"
    ]
  end

  defp summary_owned_event?(_event), do: false

  defp encode_events(events), do: Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n"))

  defp bounded_event_tail(events, limit) do
    events
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn event, {kept, size} ->
      event_size = event |> Jason.encode!() |> byte_size() |> Kernel.+(1)

      if size + event_size <= limit,
        do: {:cont, {[event | kept], size + event_size}},
        else: {:halt, {kept, size}}
    end)
    |> elem(0)
  end

  defp append_markdown_event(path, line) do
    line = IO.iodata_to_binary(line)
    current_size = file_size(path)

    if current_size + byte_size(line) <= @max_summary_bytes do
      File.write!(path, line, [:append])
    else
      existing =
        case File.read(path) do
          {:ok, payload} -> keep_binary_tail(payload, div(@max_summary_bytes, 2))
          {:error, _reason} -> ""
        end

      File.write!(path, existing <> line)
    end
  end

  defp keep_binary_tail(value, limit) when byte_size(value) <= limit, do: value
  defp keep_binary_tail(value, limit), do: binary_part(value, byte_size(value) - limit, limit)

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      {:error, :enoent} -> 0
      {:error, reason} -> raise File.Error, reason: reason, action: "stat", path: path
    end
  end

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

  defp markdown_header(workspace, issue, attrs) do
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
  end

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

  defp first_edit_marker_path(workspace, issue),
    do: Path.join(Path.dirname(paths(workspace, issue).audit_events_path), @first_edit_marker)

  defp audit_targets(workspace, issue) do
    local = if File.dir?(workspace), do: [audit_dir(workspace)], else: []
    Enum.uniq([central_audit_dir(workspace, issue) | local])
  end

  defp central_audit_dir(workspace, issue) do
    Process.get(central_audit_context_key(workspace, issue)) ||
      central_audit_base_dir(workspace, issue)
  end

  defp bind_central_audit_attempt(workspace, issue) do
    run_id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    base = central_audit_base_dir(workspace, issue)
    attempts = Path.join(base, "attempts")
    directory = Path.join(attempts, run_id)
    active_name = active_attempt_name(base, run_id)

    try do
      start_active_attempt_guardian!(active_name)

      case register_central_audit_attempt(base, attempts, directory, run_id) do
        :ok ->
          Process.put(central_audit_context_key(workspace, issue), directory)
          {:ok, run_id}

        {:error, _reason} = error ->
          cleanup_failed_central_audit_attempt(active_name, directory, error)
      end
    rescue
      error ->
        cleanup_failed_central_audit_attempt(
          active_name,
          directory,
          {:error, {:central_run_audit_registration_failed, Exception.message(error)}}
        )
    catch
      kind, reason ->
        cleanup_failed_central_audit_attempt(
          active_name,
          directory,
          {:error, {:central_run_audit_registration_failed, {kind, reason}}}
        )
    end
  end

  defp cleanup_failed_central_audit_attempt(active_name, directory, error) do
    stop_result = stop_active_attempt_guardian(active_name)
    remove_result = File.rm_rf(directory)

    case {stop_result, remove_result} do
      {:ok, {:ok, _removed}} ->
        error

      {stop_error, {:ok, _removed}} ->
        {:error, {:central_run_audit_guardian_cleanup_failed, stop_error, error}}

      {:ok, {:error, reason, path}} ->
        {:error, {:central_run_audit_directory_cleanup_failed, path, reason, error}}

      {stop_error, {:error, reason, path}} ->
        {:error, {:central_run_audit_cleanup_failed, stop_error, {path, reason}, error}}
    end
  end

  defp register_central_audit_attempt(base, attempts, directory, run_id) do
    result =
      :global.trans(
        {{__MODULE__, :central_audit_retention, base}, self()},
        fn ->
          File.mkdir_p!(directory)
          File.touch!(Path.join(directory, @active_attempt_marker))
          retain_central_audit_attempts(base, attempts, run_id)
        end
      )

    case result do
      :ok -> :ok
      {:aborted, reason} -> {:error, {:central_run_audit_registration_aborted, reason}}
      other -> {:error, {:central_run_audit_registration_failed, other}}
    end
  rescue
    error ->
      {:error, {:central_run_audit_registration_failed, Exception.message(error)}}
  catch
    kind, reason ->
      {:error, {:central_run_audit_registration_failed, {kind, reason}}}
  end

  defp retain_central_audit_attempts(base, attempts, run_id) do
    manifest_path = Path.join(base, @attempt_manifest)
    on_disk = attempt_ids_on_disk(attempts)
    current = List.wrap(run_id)

    retained =
      manifest_path
      |> read_attempt_manifest()
      |> Enum.filter(&(&1 in on_disk))
      |> Kernel.--(current)

    discovered =
      on_disk
      |> Kernel.--(retained)
      |> Kernel.--(current)
      |> Enum.sort_by(&attempt_recency(attempts, &1))

    candidates = Enum.uniq(retained ++ discovered ++ current)

    classified =
      Enum.map(candidates, fn attempt ->
        {attempt, attempt_state(base, attempts, attempt)}
      end)

    active = for {attempt, :active} <- classified, do: attempt
    completed = for {attempt, :completed} <- classified, do: attempt

    abandoned =
      classified
      |> Enum.flat_map(fn
        {attempt, :abandoned} -> [attempt]
        {_attempt, _state} -> []
      end)
      |> Enum.sort_by(&attempt_recency(attempts, &1))

    ordered_candidates = (candidates -- abandoned) ++ abandoned
    write_attempt_manifest(manifest_path, ordered_candidates)

    Enum.each(abandoned, fn attempt ->
      File.rm(Path.join([attempts, attempt, @active_attempt_marker]))
    end)

    keep_set =
      active
      |> Kernel.++(Enum.take(completed ++ abandoned, -@retained_central_attempts))
      |> MapSet.new()

    keep = Enum.filter(ordered_candidates, &MapSet.member?(keep_set, &1))

    ordered_candidates
    |> Kernel.--(keep)
    |> Enum.each(&File.rm_rf!(Path.join(attempts, &1)))

    write_attempt_manifest(manifest_path, keep)
  end

  defp attempt_ids_on_disk(attempts) do
    attempts
    |> File.ls!()
    |> Enum.filter(fn attempt ->
      safe_attempt_id?(attempt) and File.dir?(Path.join(attempts, attempt))
    end)
  end

  defp attempt_recency(attempts, attempt) do
    case File.stat(Path.join(attempts, attempt), time: :posix) do
      {:ok, %{mtime: modified_at}} -> {modified_at, attempt}
      {:error, _reason} -> {0, attempt}
    end
  end

  defp attempt_state(base, attempts, attempt) do
    marker? = File.exists?(Path.join([attempts, attempt, @active_attempt_marker]))
    owner? = :global.whereis_name(active_attempt_name(base, attempt)) != :undefined

    cond do
      marker? and owner? -> :active
      marker? -> :abandoned
      true -> :completed
    end
  end

  defp active_attempt_name(base, run_id),
    do: {__MODULE__, :central_audit_attempt, base, run_id}

  defp start_active_attempt_guardian!(active_name) do
    owner = self()
    ready_ref = make_ref()

    guardian =
      spawn(fn ->
        owner_monitor = Process.monitor(owner)
        registration = :global.register_name(active_name, self())
        send(owner, {ready_ref, registration})

        if registration == :yes do
          guard_active_attempt(owner, owner_monitor, active_name)
        end
      end)

    receive do
      {^ready_ref, :yes} ->
        guardian

      {^ready_ref, :no} ->
        raise "central run-audit owner registration failed"
    after
      @active_attempt_guard_timeout_ms ->
        Process.exit(guardian, :kill)
        raise "central run-audit owner registration timed out"
    end
  end

  defp guard_active_attempt(owner, owner_monitor, active_name) do
    receive do
      {:stop, recipient, stop_ref} ->
        :global.unregister_name(active_name)
        send(recipient, {stop_ref, :stopped})

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        :global.unregister_name(active_name)
    end
  end

  defp stop_active_attempt_guardian(active_name) do
    case :global.whereis_name(active_name) do
      :undefined ->
        :ok

      guardian ->
        monitor = Process.monitor(guardian)
        stop_ref = make_ref()
        send(guardian, {:stop, self(), stop_ref})

        receive do
          {^stop_ref, :stopped} ->
            Process.demonitor(monitor, [:flush])
            :ok
        after
          @active_attempt_guard_timeout_ms ->
            Process.exit(guardian, :kill)

            receive do
              {:DOWN, ^monitor, :process, ^guardian, _reason} ->
                :global.unregister_name(active_name)
                :ok
            after
              @active_attempt_guard_timeout_ms ->
                Process.demonitor(monitor, [:flush])
                {:error, :central_run_audit_owner_stop_timeout}
            end
        end
    end
  end

  defp complete_central_audit_attempt(workspace, issue) do
    base = central_audit_base_dir(workspace, issue)
    attempts = Path.join(base, "attempts")
    directory = central_audit_dir(workspace, issue)

    if Path.dirname(directory) == attempts do
      run_id = Path.basename(directory)
      active_name = active_attempt_name(base, run_id)
      finalize_central_audit_attempt(base, attempts, directory, active_name)
    else
      :ok
    end
  end

  defp finalize_central_audit_attempt(base, attempts, directory, active_name) do
    run_id = Path.basename(directory)

    result =
      :global.trans(
        {{__MODULE__, :central_audit_retention, base}, self()},
        fn ->
          with :ok <- stop_active_attempt_guardian(active_name),
               :ok <- remove_active_attempt_marker(directory) do
            retain_central_audit_attempts(base, attempts, run_id)
          end
        end
      )

    case result do
      :ok -> :ok
      {:aborted, reason} -> {:error, {:central_run_audit_completion_aborted, reason}}
      {:error, _reason} = error -> error
      other -> {:error, {:central_run_audit_completion_failed, other}}
    end
  rescue
    error ->
      {:error, {:central_run_audit_completion_failed, Exception.message(error)}}
  catch
    kind, reason ->
      {:error, {:central_run_audit_completion_failed, {kind, reason}}}
  end

  defp remove_active_attempt_marker(directory) do
    case File.rm(Path.join(directory, @active_attempt_marker)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:central_run_audit_marker_removal_failed, reason}}
    end
  end

  defp read_attempt_manifest(path) do
    with {:ok, payload} <- File.read(path),
         {:ok, attempts} when is_list(attempts) <- Jason.decode(payload) do
      Enum.filter(attempts, &safe_attempt_id?/1)
    else
      _missing_or_invalid -> []
    end
  end

  defp write_attempt_manifest(path, attempts) do
    temporary = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    try do
      File.write!(temporary, Jason.encode!(attempts))
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp safe_attempt_id?(attempt) when is_binary(attempt),
    do: Regex.match?(~r/^[A-Za-z0-9_-]+$/, attempt)

  defp safe_attempt_id?(_attempt), do: false

  defp central_audit_context_key(workspace, issue),
    do: {__MODULE__, :central_audit_dir, workspace, issue.id || issue.identifier || "unknown"}

  defp central_audit_base_dir(workspace, issue) do
    root =
      Application.get_env(:symphony_elixir, :execution_state_root) ||
        :filename.basedir(:user_data, "symphony") |> to_string() |> Path.join("execution")

    key =
      [workspace, <<0>>, issue.id || issue.identifier || "unknown"]
      |> IO.iodata_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Path.join([root, "run-audits", key])
  end

  defp fallback_audit_dir(workspace, issue, run_id) do
    if File.dir?(workspace) do
      audit_dir(workspace)
    else
      key =
        [workspace, <<0>>, issue.id || issue.identifier || "unknown"]
        |> IO.iodata_to_binary()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      Path.join([System.tmp_dir!(), "symphony-run-audit-fallback", key, run_id])
    end
  end

  defp with_audit_guard(workspace, fun) when is_function(fun, 0) do
    fun.()
    :ok
  rescue
    error ->
      Logger.warning("Failed to write run audit workspace=#{workspace}: #{Exception.message(error)}")
      :ok
  end
end
