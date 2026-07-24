defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000
  @stale_after_seconds 120

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, nil)
      |> assign(:agents, [])
      |> assign(:selected_agent_id, nil)
      |> assign(:selected_agent, nil)
      |> assign(:dashboard_state, "loading")
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
      {:ok, refresh_dashboard(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("select-agent", %{"agent-id" => agent_id}, socket) do
    case Enum.find(socket.assigns.agents, &(&1.id == agent_id)) do
      nil ->
        {:noreply, socket}

      agent ->
        {:noreply,
         socket
         |> assign(:selected_agent_id, agent_id)
         |> assign(:selected_agent, Presenter.dashboard_detail(agent))}
    end
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()

    {:noreply,
     socket
     |> refresh_selected_agent_detail()
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, refresh_dashboard(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id="dashboard-root"
      class="dashboard-shell"
      data-dashboard-state={@dashboard_state}
      phx-hook="PreserveDashboardReadingPosition"
    >
      <header class="dashboard-header">
        <div>
          <p class="eyebrow">Symphony Observability</p>
          <h1>Operations Dashboard</h1>
          <p class="header-copy">Live agent work, attention states, and recent session activity.</p>
        </div>

        <div class="connection-status" role="status" aria-live="polite">
          <span class="status-badge status-badge-live">
            <span class="status-badge-dot" aria-hidden="true"></span>
            Live
          </span>
          <span class="status-badge status-badge-offline">
            <span class="status-badge-dot" aria-hidden="true"></span>
            Offline
          </span>
        </div>
      </header>

      <%= cond do %>
        <% @dashboard_state == "loading" -> %>
          <section class="dashboard-message dashboard-loading" role="status" aria-live="polite">
            <span class="loading-mark" aria-hidden="true"></span>
            <div>
              <h2>Loading agent status</h2>
              <p>Connecting to the current Symphony runtime.</p>
            </div>
          </section>
        <% @payload && @payload[:error] -> %>
          <section class="dashboard-message dashboard-error" role="alert">
            <p class="message-kicker">Runtime unavailable</p>
            <h2>Snapshot unavailable</h2>
            <p><strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %></p>
            <p>Symphony retries automatically. Check the runtime process if this state persists.</p>
          </section>
        <% @agents == [] and is_nil(@selected_agent) -> %>
          <section class="dashboard-message dashboard-empty" role="status">
            <p class="message-kicker">All clear</p>
            <h2>No agents need monitoring</h2>
            <p>Active, retrying, and blocked sessions will appear here when work starts.</p>
          </section>
        <% true -> %>
          <section class="fleet-summary" aria-label="Agent summary">
            <div class="summary-counts" aria-label="Agent counts">
              <span><strong class="numeric"><%= @payload.counts.running %></strong> running</span>
              <span><strong class="numeric"><%= @payload.counts.retrying %></strong> retrying</span>
              <span><strong class="numeric"><%= @payload.counts.blocked %></strong> blocked</span>
            </div>
          </section>

          <div class="agent-workspace">
            <aside class="agent-overview" aria-labelledby="agent-overview-title">
              <div class="panel-heading">
                <div>
                  <p class="panel-kicker">Fleet</p>
                  <h2 id="agent-overview-title">Agents</h2>
                </div>
                <span class="agent-total numeric"><%= length(@agents) %></span>
              </div>

              <div class="agent-list">
                <div
                  :for={agent <- @agents}
                  class={[
                    "agent-row-wrap",
                    @selected_agent_id == agent.id && "agent-row-selected"
                  ]}
                  data-agent-status={effective_status(agent, @now)}
                >
                  <button
                    id={"agent-#{dom_id(agent.id)}"}
                    type="button"
                    class="agent-row"
                    phx-click="select-agent"
                    phx-value-agent-id={agent.id}
                    aria-pressed={to_string(@selected_agent_id == agent.id)}
                    aria-controls="agent-detail"
                  >
                    <span class="agent-row-topline">
                      <span class="agent-issue"><%= agent.issue_identifier %></span>
                      <span class={["agent-status", "agent-status-#{effective_status(agent, @now)}"]}>
                        <span class="agent-status-mark" aria-hidden="true"></span>
                        <%= effective_status_label(agent, @now) %>
                      </span>
                    </span>
                    <span class="agent-activity"><%= agent.activity %></span>
                    <span
                      :if={agent.reason && agent.reason != agent.activity}
                      class="agent-reason"
                    ><%= agent.reason %></span>
                    <span class="agent-time">
                      <%= activity_time_label(agent, @now) %>
                    </span>
                  </button>
                  <a
                    :if={external_issue_url(agent.issue_url)}
                    class="agent-row-issue-link"
                    href={external_issue_url(agent.issue_url)}
                    target="_blank"
                    rel="noopener noreferrer"
                    aria-label={"Open #{agent.issue_identifier} in the issue tracker"}
                  >Issue</a>
                </div>
              </div>
            </aside>

            <.agent_detail
              agent={@selected_agent}
              now={@now}
              rate_limits={@payload.rate_limits}
            />
          </div>
      <% end %>
    </section>
    """
  end

  attr(:agent, :map, required: true)
  attr(:now, :any, required: true)
  attr(:rate_limits, :any, required: true)

  defp agent_detail(assigns) do
    assigns =
      assigns
      |> assign(:status, effective_status(assigns.agent, assigns.now))
      |> assign(:status_label, effective_status_label(assigns.agent, assigns.now))
      |> assign(:issue_href, external_issue_url(assigns.agent.issue_url))

    ~H"""
    <section
      id="agent-detail"
      class="agent-detail"
      data-selected-agent={@agent.id}
      data-agent-status={@status}
      aria-labelledby="agent-detail-title"
    >
      <header class="detail-header">
        <div>
          <p class="panel-kicker">Selected agent</p>
          <div class="detail-title-line">
            <h2 id="agent-detail-title"><%= @agent.issue_identifier %></h2>
            <span class={["agent-status", "agent-status-#{@status}"]}>
              <span class="agent-status-mark" aria-hidden="true"></span>
              <%= @status_label %>
            </span>
          </div>
        </div>
        <%= if @issue_href do %>
          <a
            class="issue-link"
            href={@issue_href}
            target="_blank"
            rel="noopener noreferrer"
            aria-label={"Open #{@agent.issue_identifier} in the issue tracker"}
          >
            Open issue
          </a>
        <% end %>
      </header>

      <%= if @status == "unavailable" do %>
        <div class="attention-note attention-note-neutral" role="status">
          <strong>Agent unavailable</strong>
          <p>This agent is no longer present in the current runtime snapshot.</p>
          <p><strong>Next action:</strong> <%= @agent.next_action %>.</p>
        </div>
      <% else %>
        <section class="current-activity" aria-labelledby="current-activity-title">
          <p class="panel-kicker">Codex update</p>
          <h3 id="current-activity-title"><%= @agent.activity %></h3>
          <p class="activity-meta">
            <%= @agent.activity_at || @agent.relevant_at || "Timestamp not reported" %>
          </p>
        </section>

        <%= if @agent.status == "retrying" do %>
          <div class="attention-note attention-note-retry">
            <strong>Retry attempt <%= @agent.attempt || "n/a" %></strong>
            <p><%= @agent.reason || "The last attempt did not complete." %></p>
            <dl class="inline-facts">
              <div><dt>Next retry</dt><dd><%= @agent.due_at || "Not scheduled" %></dd></div>
              <div><dt>Next action</dt><dd><%= @agent.next_action %></dd></div>
            </dl>
          </div>
        <% end %>

        <%= if @agent.status == "blocked" do %>
          <div class="attention-note attention-note-blocked">
            <strong>Approval or input needed</strong>
            <p><%= @agent.reason || "The agent is waiting for operator input." %></p>
            <dl class="inline-facts">
              <div><dt>Blocked at</dt><dd><%= @agent.relevant_at || "Not reported" %></dd></div>
              <div><dt>Next action</dt><dd><%= @agent.next_action %></dd></div>
            </dl>
          </div>
        <% end %>
      <% end %>

      <section class="log-section" aria-labelledby="log-title">
        <div class="panel-heading log-heading">
          <div>
            <p class="panel-kicker">Selected session</p>
            <h3 id="log-title">Live log tail</h3>
          </div>
          <span class="log-count">
            <span
              id="log-follow-state"
              class="log-follow-state"
              data-log-follow-state="following"
              role="status"
              aria-live="polite"
            >Following</span>
            <span class="numeric"><%= length(@agent.log_tail) %></span>
          </span>
        </div>

        <ol
          id="agent-detail-log"
          class="log-tail"
          role="log"
          aria-labelledby="log-title"
          aria-live="off"
          tabindex="0"
        >
          <li :for={entry <- @agent.log_tail} class="log-line">
            <time class="log-time mono" datetime={entry.at} title={entry.at}>
              <%= log_time(entry.at) %>
            </time>
            <span class="log-event"><%= log_event(entry.event) %></span>
            <span class="log-message"><%= entry.message %></span>
          </li>
        </ol>
        <p :if={@agent.log_tail == []} class="log-empty">
          No audit output is available for this session yet.
        </p>
      </section>

      <dl class="detail-facts">
        <div>
          <dt>Runtime</dt>
          <dd id="agent-detail-runtime" class="numeric"><%= runtime_for_agent(@agent, @now) %></dd>
        </div>
        <div>
          <dt>Turns</dt>
          <dd class="numeric"><%= @agent.turn_count || "n/a" %></dd>
        </div>
        <div>
          <dt>Last activity</dt>
          <dd class="mono"><%= @agent.activity_at || "n/a" %></dd>
        </div>
      </dl>

      <section class="timeline-section" aria-labelledby="timeline-title">
        <div class="panel-heading timeline-heading">
          <div>
            <p class="panel-kicker">Recent audit events</p>
            <h3 id="timeline-title">Recent activity</h3>
          </div>
          <span class="event-count numeric"><%= length(@agent.timeline) %></span>
        </div>

        <ol id="agent-detail-timeline" class="timeline" aria-live="polite">
          <li :for={event <- @agent.timeline}>
            <span class="timeline-mark" aria-hidden="true"></span>
            <div>
              <p><%= event.message %></p>
              <span class="timeline-meta">
                <%= event.event %>
                <%= if event.at do %> · <span class="mono"><%= event.at %></span><% end %>
              </span>
            </div>
          </li>
        </ol>
        <p :if={@agent.timeline == []} class="timeline-empty">
          No recent audit events are available for this session.
        </p>
      </section>

      <details class="detail-disclosure">
        <summary>Session and workspace</summary>
        <dl class="disclosure-facts">
          <div>
            <dt>Session ID</dt>
            <dd>
              <span class="mono"><%= @agent.session_id || "n/a" %></span>
              <button
                :if={@agent.session_id}
                type="button"
                class="copy-button"
                data-copy={@agent.session_id}
                data-copy-name="Session ID"
                aria-describedby="copy-feedback"
              >Copy ID</button>
            </dd>
          </div>
          <div><dt>Worker</dt><dd><%= @agent.worker_host || "n/a" %></dd></div>
          <div><dt>Workspace</dt><dd class="mono"><%= @agent.workspace_path || "n/a" %></dd></div>
        </dl>
      </details>

      <details class="detail-disclosure">
        <summary>Audit and diagnostics</summary>
        <dl class="disclosure-facts">
          <div>
            <dt>Audit</dt>
            <dd>
              <span class="mono"><%= @agent.audit_path || "n/a" %></span>
              <button
                :if={@agent.audit_path}
                type="button"
                class="copy-button"
                data-copy={@agent.audit_path}
                data-copy-name="audit path"
                aria-describedby="copy-feedback"
              >Copy audit</button>
            </dd>
          </div>
          <div :if={browser_path(@agent.capability_diagnostics)}>
            <dt>Browser verification:</dt>
            <dd>
              <strong><%= browser_path(@agent.capability_diagnostics) %></strong>
              <span>
                <%= browser_provenance(@agent.capability_diagnostics) %>
                · <%= browser_code(@agent.capability_diagnostics) %>
              </span>
            </dd>
          </div>
          <div>
            <dt>Rate limits</dt>
            <dd><%= rate_limit_summary(@rate_limits) %></dd>
          </div>
        </dl>
      </details>

      <p
        id="copy-feedback"
        class="copy-feedback"
        data-copy-status
        role="status"
        aria-live="polite"
        aria-atomic="true"
      ></p>
    </section>
    """
  end

  defp refresh_dashboard(socket) do
    payload = load_payload()
    agents = Presenter.dashboard_agents(payload)
    selected_agent_id = socket.assigns.selected_agent_id || first_agent_id(agents)

    selected_agent =
      case Enum.find(agents, &(&1.id == selected_agent_id)) do
        nil -> unavailable_selection(socket.assigns.selected_agent, selected_agent_id)
        agent -> Presenter.dashboard_detail(agent)
      end

    socket
    |> assign(:payload, payload)
    |> assign(:agents, agents)
    |> assign(:selected_agent_id, selected_agent_id)
    |> assign(:selected_agent, selected_agent)
    |> assign(:dashboard_state, dashboard_state(payload, agents))
    |> assign(:now, DateTime.utc_now())
  end

  defp unavailable_selection(nil, _selected_agent_id), do: nil

  defp unavailable_selection(agent, selected_agent_id) do
    agent
    |> Map.put(:id, selected_agent_id)
    |> Map.put(:status, "unavailable")
    |> Map.put(:status_label, "Unavailable")
    |> Map.put(:activity, "This agent is no longer present in the current runtime snapshot")
    |> Map.put(:next_action, "Wait for the runtime to report the agent again")
  end

  defp refresh_selected_agent_detail(%{assigns: %{selected_agent_id: nil}} = socket), do: socket

  defp refresh_selected_agent_detail(socket) do
    case Enum.find(socket.assigns.agents, &(&1.id == socket.assigns.selected_agent_id)) do
      nil -> socket
      agent -> assign(socket, :selected_agent, Presenter.dashboard_detail(agent))
    end
  end

  defp dashboard_state(%{error: _error}, _agents), do: "error"
  defp dashboard_state(_payload, []), do: "empty"
  defp dashboard_state(_payload, _agents), do: "ready"

  defp first_agent_id([agent | _agents]), do: agent.id
  defp first_agent_id([]), do: nil

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp effective_status(%{status: "running", activity_at: activity_at}, now) do
    if stale?(activity_at, now), do: "stale", else: "running"
  end

  defp effective_status(agent, _now), do: agent.status

  defp effective_status_label(agent, now) do
    case effective_status(agent, now) do
      "stale" -> "Stale"
      "unavailable" -> "Unavailable"
      _ -> agent.status_label
    end
  end

  defp stale?(activity_at, %DateTime{} = now) when is_binary(activity_at) do
    case DateTime.from_iso8601(activity_at) do
      {:ok, timestamp, _offset} -> DateTime.diff(now, timestamp, :second) >= @stale_after_seconds
      _ -> false
    end
  end

  defp stale?(_activity_at, _now), do: false

  defp activity_time_label(agent, now) do
    case effective_status(agent, now) do
      "retrying" -> "Next retry #{agent.due_at || "not scheduled"}"
      "blocked" -> "Blocked #{agent.relevant_at || "at unknown time"}"
      "stale" -> "No recent update · #{agent.activity_at}"
      _ -> agent.activity_at || agent.relevant_at || "Timestamp not reported"
    end
  end

  defp runtime_for_agent(%{started_at: started_at}, now) when not is_nil(started_at) do
    started_at
    |> runtime_seconds_from_started_at(now)
    |> format_runtime_seconds()
  end

  defp runtime_for_agent(_agent, _now), do: "n/a"

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    hours = div(whole_seconds, 3_600)
    mins = div(rem(whole_seconds, 3_600), 60)

    cond do
      hours > 0 -> "#{hours}h #{mins}m"
      mins > 0 -> "#{mins}m"
      true -> "<1m"
    end
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp browser_path(%{browser_path: %{selected: selected}}) when is_binary(selected), do: selected
  defp browser_path(_diagnostics), do: nil

  defp browser_provenance(%{browser_path: %{provenance: provenance}}) when is_binary(provenance),
    do: provenance

  defp browser_provenance(_diagnostics), do: "unknown provenance"

  defp browser_code(%{browser_path: %{code: code}}) when is_binary(code), do: code
  defp browser_code(_diagnostics), do: "unknown"

  defp rate_limit_summary(nil), do: "Not reported"
  defp rate_limit_summary(rate_limits) when map_size(rate_limits) == 0, do: "Not reported"
  defp rate_limit_summary(_rate_limits), do: "Available in the current runtime snapshot"

  defp log_time(nil), do: "--:--:--"

  defp log_time(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} ->
        datetime
        |> DateTime.to_time()
        |> Time.truncate(:second)
        |> Time.to_iso8601()

      _ ->
        timestamp
    end
  end

  defp log_event(event) when is_binary(event), do: String.replace(event, "_", " ")
  defp log_event(_event), do: "activity"

  defp dom_id(id), do: String.replace(id, ":", "-")

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end
end
