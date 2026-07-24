defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @audit_tail_bytes 64 * 1_024
  @audit_event_limit 50
  @authorization_header ~r/\b(authorization\s*:\s*)(?:(?:bearer|basic)\s+)?[^\s,;]+/i
  @bearer_token ~r/\b(bearer\s+)[A-Za-z0-9._~+\/=-]+/i
  @secret_assignment ~r/\b((?:[A-Za-z0-9_-]*(?:api[_-]?key|token|secret|password|signature)[A-Za-z0-9_-]*)\s*[=:]\s*)(?:"[^"]*"|'[^']*'|[^\s&;,]+)/i

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, []))
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @doc """
  Projects the existing observability payload into dashboard-only agent summaries.

  This deliberately leaves `state_payload/2` and `issue_payload/3` unchanged for API
  consumers. Audit history is not read while building the overview.
  """
  @spec dashboard_agents(map()) :: [map()]
  def dashboard_agents(payload) when is_map(payload) do
    running =
      payload
      |> Map.get(:running, [])
      |> Enum.map(&dashboard_running_agent/1)

    retrying =
      payload
      |> Map.get(:retrying, [])
      |> Enum.map(&dashboard_retrying_agent/1)

    blocked =
      payload
      |> Map.get(:blocked, [])
      |> Enum.map(&dashboard_blocked_agent/1)

    running ++ retrying ++ blocked
  end

  @doc """
  Adds bounded log output to one selected dashboard agent.
  """
  @spec dashboard_detail(map()) :: map()
  def dashboard_detail(agent) when is_map(agent) do
    audit_events =
      agent
      |> Map.get(:audit_events_path)
      |> read_audit_events()

    Map.put(agent, :log_tail, audit_events)
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked),
        host: workspace_host(running, retry, blocked),
        audit_path: audit_path(running, retry, blocked),
        audit_events_path: audit_events_path(running, retry, blocked)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload(running || blocked),
      last_error: (blocked && blocked.error) || (retry && retry.error),
      tracked: %{}
    }
  end

  defp dashboard_running_agent(entry) do
    %{
      id: entry.issue_id,
      issue_id: entry.issue_id,
      issue_identifier: entry.issue_identifier,
      issue_url: entry.issue_url,
      status: "running",
      status_label: "Running",
      state: entry.state,
      activity: entry.last_message || to_string(entry.last_event || "Waiting for agent activity"),
      activity_at: entry.last_event_at,
      relevant_at: entry.started_at,
      reason: nil,
      next_action: "Monitor progress",
      session_id: entry.session_id,
      worker_host: entry.worker_host,
      workspace_path: entry.workspace_path,
      audit_path: entry.audit_path,
      audit_events_path: entry.audit_events_path,
      capability_diagnostics: entry.capability_diagnostics,
      turn_count: entry.turn_count,
      started_at: entry.started_at,
      tokens: entry.tokens,
      attempt: nil,
      due_at: nil
    }
  end

  defp dashboard_retrying_agent(entry) do
    %{
      id: entry.issue_id,
      issue_id: entry.issue_id,
      issue_identifier: entry.issue_identifier,
      issue_url: entry.issue_url,
      status: "retrying",
      status_label: "Retrying",
      state: "Retrying",
      activity: entry.error || "Waiting for the next retry window",
      activity_at: entry.due_at,
      relevant_at: entry.due_at,
      reason: entry.error,
      next_action: "Wait for the retry window",
      session_id: nil,
      worker_host: entry.worker_host,
      workspace_path: entry.workspace_path,
      audit_path: entry.audit_path,
      audit_events_path: entry.audit_events_path,
      capability_diagnostics: entry.capability_diagnostics,
      turn_count: nil,
      started_at: nil,
      tokens: nil,
      attempt: entry.attempt,
      due_at: entry.due_at
    }
  end

  defp dashboard_blocked_agent(entry) do
    %{
      id: entry.issue_id,
      issue_id: entry.issue_id,
      issue_identifier: entry.issue_identifier,
      issue_url: entry.issue_url,
      status: "blocked",
      status_label: "Approval or input needed",
      state: entry.state,
      activity: entry.last_message || entry.error || "Waiting for operator input",
      activity_at: entry.last_event_at,
      relevant_at: entry.blocked_at,
      reason: entry.error,
      next_action: "Review the request and provide the required input",
      session_id: entry.session_id,
      worker_host: entry.worker_host,
      workspace_path: entry.workspace_path,
      audit_path: entry.audit_path,
      audit_events_path: entry.audit_events_path,
      capability_diagnostics: entry.capability_diagnostics,
      turn_count: nil,
      started_at: nil,
      tokens: nil,
      attempt: nil,
      due_at: nil
    }
  end

  defp read_audit_events(path) when is_binary(path) and path != "" do
    with {:ok, %{size: size}} <- File.stat(path),
         {:ok, data} <- read_audit_tail(path, size) do
      offset = max(size - @audit_tail_bytes, 0)

      data
      |> discard_partial_line(offset)
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&decode_audit_event/1)
      |> Enum.sort_by(&(&1.at || ""))
      |> Enum.take(-@audit_event_limit)
    else
      _ -> []
    end
  end

  defp read_audit_events(_path), do: []

  defp read_audit_tail(path, size) do
    offset = max(size - @audit_tail_bytes, 0)
    length = min(size, @audit_tail_bytes)

    case :file.open(String.to_charlist(path), [:read, :binary]) do
      {:ok, device} ->
        result =
          case :file.pread(device, offset, length) do
            {:ok, data} -> {:ok, data}
            :eof -> {:ok, ""}
            error -> error
          end

        :ok = :file.close(device)
        result

      error ->
        error
    end
  end

  defp discard_partial_line(data, 0), do: data

  defp discard_partial_line(data, _offset) do
    case :binary.split(data, "\n") do
      [_partial, rest] -> rest
      [_partial] -> ""
    end
  end

  defp decode_audit_event(line) do
    case Jason.decode(line) do
      {:ok, %{} = event} ->
        at = first_binary(event, ["timestamp", "recorded_at", "at"])
        kind = first_binary(event, ["phase", "event", "type", "method"]) || "activity"

        message =
          event
          |> first_binary(["detail", "message", "summary", "command", "method"])
          |> redact_sensitive()
          |> append_exit_code(Map.get(event, "exit_code"))
          |> Kernel.||(kind)

        [%{at: at, event: kind, message: message}]

      _ ->
        []
    end
  end

  defp first_binary(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp append_exit_code(message, exit_code) when is_binary(message) and is_integer(exit_code),
    do: "#{message} · exit #{exit_code}"

  defp append_exit_code(message, _exit_code), do: message

  defp redact_sensitive(message) when is_binary(message) do
    message
    |> String.replace(@authorization_header, "\\1[REDACTED]")
    |> String.replace(@bearer_token, "\\1[REDACTED]")
    |> String.replace(@secret_assignment, "\\1[REDACTED]")
  end

  defp redact_sensitive(message), do: message

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _blocked) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _blocked) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, _blocked), do: "blocked"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      audit_path: Map.get(entry, :audit_path),
      audit_events_path: Map.get(entry, :audit_events_path),
      capability_diagnostics: Map.get(entry, :capability_diagnostics),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      audit_path: Map.get(entry, :audit_path),
      audit_events_path: Map.get(entry, :audit_events_path),
      capability_diagnostics: Map.get(entry, :capability_diagnostics)
    }
  end

  defp blocked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      audit_path: Map.get(entry, :audit_path),
      audit_events_path: Map.get(entry, :audit_events_path),
      capability_diagnostics: Map.get(entry, :capability_diagnostics),
      session_id: entry.session_id,
      blocked_at: iso8601(entry.blocked_at),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      last_event_at: iso8601(entry.last_codex_timestamp)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      audit_path: Map.get(running, :audit_path),
      audit_events_path: Map.get(running, :audit_events_path),
      capability_diagnostics: Map.get(running, :capability_diagnostics),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path),
      audit_path: Map.get(retry, :audit_path),
      audit_events_path: Map.get(retry, :audit_events_path),
      capability_diagnostics: Map.get(retry, :capability_diagnostics)
    }
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      audit_path: Map.get(blocked, :audit_path),
      audit_events_path: Map.get(blocked, :audit_events_path),
      capability_diagnostics: Map.get(blocked, :capability_diagnostics),
      session_id: blocked.session_id,
      state: blocked.state,
      error: blocked.error,
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp)
    }
  end

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp audit_path(running, retry, blocked) do
    (running && Map.get(running, :audit_path)) ||
      (retry && Map.get(retry, :audit_path)) ||
      (blocked && Map.get(blocked, :audit_path))
  end

  defp audit_events_path(running, retry, blocked) do
    (running && Map.get(running, :audit_events_path)) ||
      (retry && Map.get(retry, :audit_events_path)) ||
      (blocked && Map.get(blocked, :audit_events_path))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    [
      %{
        at: iso8601(entry.last_codex_timestamp),
        event: entry.last_codex_event,
        message: summarize_message(entry.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
