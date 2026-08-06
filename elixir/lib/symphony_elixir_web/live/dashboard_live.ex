defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.GitHubRepository
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
      |> assign(:request_id, nil)
      |> assign(:selected_team, nil)
      |> assign(:selected_member_id, nil)
      |> assign(:selected_member, nil)
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
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:request_id, Map.get(params, "request_id"))
     |> refresh_team_selection()}
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

  def handle_event("select-member", %{"member-id" => member_id}, socket) do
    case socket.assigns.selected_team do
      %{agents: agents} ->
        case Enum.find(agents, &(&1.agent_id == member_id)) do
          nil ->
            {:noreply, socket}

          member ->
            {:noreply,
             socket
             |> assign(:selected_member_id, member_id)
             |> assign(:selected_member, member)}
        end

      _other ->
        {:noreply, socket}
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
    assigns = assign(assigns, :reading_context, reading_context(assigns))

    ~H"""
    <section
      id="dashboard-root"
      class="dashboard-shell"
      data-dashboard-state={@dashboard_state}
      data-reading-context={@reading_context}
      phx-hook="PreserveDashboardReadingPosition"
    >
      <.app_navigation live_action={@live_action} />

      <%= case @live_action do %>
        <% :teams -> %>
          <.teams_page payload={@payload} dashboard_state={@dashboard_state} />
        <% :team -> %>
          <.team_page
            payload={@payload}
            dashboard_state={@dashboard_state}
            request_id={@request_id}
            team={@selected_team}
            member={@selected_member}
            selected_member_id={@selected_member_id}
          />
        <% _operations -> %>
          <.operations_page
            payload={@payload}
            agents={@agents}
            selected_agent_id={@selected_agent_id}
            selected_agent={@selected_agent}
            dashboard_state={@dashboard_state}
            now={@now}
          />
      <% end %>
    </section>
    """
  end

  defp app_navigation(assigns) do
    ~H"""
    <header class="app-navigation-shell">
      <div class="app-navigation-main">
        <.link navigate="/" class="app-brand">
          <span>Symphony</span><span class="app-brand-optional"> Observability</span>
        </.link>
        <nav class="app-navigation" aria-label="Primary navigation">
          <.link
            navigate="/"
            class={["app-navigation-link", @live_action == :operations && "app-navigation-current"]}
            aria-current={@live_action == :operations && "page"}
          >Operations</.link>
          <.link
            navigate="/teams"
            class={["app-navigation-link", @live_action in [:teams, :team] && "app-navigation-current"]}
            aria-current={@live_action in [:teams, :team] && "page"}
          >Teams</.link>
        </nav>
      </div>

      <div class="connection-status" role="status" aria-live="polite">
        <span class="connection-label status-badge-live">
          <span class="status-badge-dot" aria-hidden="true"></span>
          Live
        </span>
        <span class="connection-label status-badge-offline">
          <span class="status-badge-dot" aria-hidden="true"></span>
          Offline
        </span>
      </div>
    </header>
    """
  end

  defp teams_page(assigns) do
    teams = payload_teams(assigns.payload)

    assigns =
      assigns
      |> assign(:teams, teams)
      |> assign(:member_count, Enum.sum(Enum.map(teams, &length(&1.agents))))
      |> assign(:attention_count, Enum.count(teams, &team_needs_attention?/1))

    ~H"""
    <div class="page-content teams-page">
      <header class="page-header">
        <h1>Teams</h1>
        <p>Coordinated work across repositories, members, and handoffs.</p>
      </header>

      <%= cond do %>
        <% is_nil(@payload) -> %>
          <.dashboard_loading />
        <% @payload[:error] -> %>
          <.dashboard_error error={@payload.error} />
        <% @teams == [] -> %>
          <section class="dashboard-message dashboard-empty" role="status">
            <h2>No active teams</h2>
            <p>Team Mode requests will appear here when coordinated work starts.</p>
          </section>
        <% true -> %>
          <p class="team-page-summary">
            <strong><%= length(@teams) %></strong> active <%= pluralize(length(@teams), "team") %>
            <span aria-hidden="true">·</span>
            <strong><%= @member_count %></strong> <%= pluralize(@member_count, "member") %>
            <%= if @attention_count > 0 do %>
              <span aria-hidden="true">·</span>
              <strong class="attention-count"><%= @attention_count %> needs attention</strong>
            <% end %>
          </p>

          <section class="teams-index" aria-labelledby="active-teams-title">
            <div class="panel-heading">
              <h2 id="active-teams-title">Active team requests</h2>
              <span class="agent-total numeric"><%= length(@teams) %></span>
            </div>

            <div class="teams-index-list">
              <.team_index_row :for={team <- @teams} team={team} />
            </div>
          </section>
      <% end %>
    </div>
    """
  end

  defp team_index_row(assigns) do
    assigns =
      assigns
      |> assign(:attention?, team_needs_attention?(assigns.team))
      |> assign(:summary, team_summary(assigns.team))
      |> assign(:latest_event, assigns.team.latest_event)

    ~H"""
    <article class="team-index-row" data-team-request={@team.request_id}>
      <div class="team-index-identity">
        <h3><%= team_label(@team) %></h3>
        <p>Team Mode request</p>
      </div>
      <div class="team-index-state">
        <span class={[@attention? && "team-state-attention", !@attention? && "team-state-active"]}>
          <span class="team-state-mark" aria-hidden="true"></span>
          <%= if @attention?, do: "Needs attention", else: "Active" %>
        </span>
        <p><%= @summary %></p>
      </div>
      <div class="team-index-event">
        <p class="team-index-label">Latest event</p>
        <%= if @latest_event do %>
          <p>
            <span class="team-event-route">
              <%= member_label(@team, @latest_event.sender) %>
              <span aria-hidden="true">→</span>
              <%= member_label(@team, @latest_event.recipient) %>
            </span>
            <span class="team-event-kind"><%= @latest_event.kind %></span>
            <span><%= @latest_event.message %></span>
          </p>
        <% else %>
          <p>Waiting for the first member event.</p>
        <% end %>
      </div>
      <.link class="team-index-action" navigate={"/teams/#{@team.request_id}"}>
        <%= if @attention?, do: "Review blocker", else: "View activity" %>
        <span aria-hidden="true">→</span>
      </.link>
    </article>
    """
  end

  defp team_page(assigns) do
    assigns = assign(assigns, :summary, assigns.team && team_summary(assigns.team))

    ~H"""
    <div class="page-content team-page">
      <%= cond do %>
        <% is_nil(@payload) -> %>
          <.dashboard_loading />
        <% @payload[:error] -> %>
          <.dashboard_error error={@payload.error} />
        <% is_nil(@team) -> %>
          <section class="dashboard-message dashboard-empty" role="status">
            <h1>Team unavailable</h1>
            <p>The active runtime no longer reports <strong><%= @request_id %></strong>.</p>
            <.link class="inline-navigation" navigate="/teams">← Back to Teams</.link>
          </section>
        <% true -> %>
          <nav class="breadcrumb" aria-label="Breadcrumb">
            <.link navigate="/teams"><span aria-hidden="true">←</span> Teams</.link>
            <span aria-hidden="true">/</span>
            <span aria-current="page"><%= @team.request_id %></span>
          </nav>

          <header class="team-page-header">
            <h1><%= team_label(@team) %></h1>
            <p><%= @team.request_id %> · Team activity across <%= length(@team.agents) %> members.</p>
            <p class="team-page-summary"><%= @summary %></p>
          </header>

          <section
            id="team-detail"
            class="team-detail"
            data-team-request={@team.request_id}
            data-selected-member={@selected_member_id}
            aria-label={"#{team_label(@team)} team activity"}
          >
            <aside class="team-members" aria-labelledby="team-members-title">
              <div class="team-section-heading">
                <h2 id="team-members-title">Members</h2>
                <span class="agent-total numeric"><%= length(@team.agents) %></span>
              </div>

              <div class="team-member-list">
                <div
                  :for={member <- @team.agents}
                  class={[
                    "team-member-wrap",
                    @selected_member_id == member.agent_id && "team-member-selected"
                  ]}
                >
                  <button
                    id={"team-member-#{dom_id(member.agent_id)}"}
                    type="button"
                    class="team-member"
                    phx-click="select-member"
                    phx-value-member-id={member.agent_id}
                    aria-pressed={to_string(@selected_member_id == member.agent_id)}
                    aria-controls="team-member-details team-event-log"
                  >
                    <span class="team-member-heading">
                      <strong><%= member_display_name(member) %></strong>
                      <span class={team_member_status_class(member.status)}>
                        <span class="team-state-mark" aria-hidden="true"></span>
                        <%= team_member_status_label(member.status) %>
                      </span>
                    </span>
                    <span :if={member.repository} class="team-member-repository"><%= member.repository %></span>
                    <span class="team-member-activity"><%= member_activity(member) %></span>
                  </button>
                  <a
                    :if={pull_request(member.pr_url)}
                    class="team-member-pr"
                    href={pull_request(member.pr_url).href}
                    target="_blank"
                    rel="noopener noreferrer"
                    aria-label={"GitHub #{pull_request(member.pr_url).label}"}
                  ><%= pull_request(member.pr_url).label %></a>
                </div>
              </div>

              <details :if={@member} id="team-member-details" class="member-disclosure" open>
                <summary>Member details</summary>
                <dl class="member-facts">
                  <div><dt>Role</dt><dd><%= @member.role || "n/a" %></dd></div>
                  <div><dt>Thread</dt><dd class="mono"><%= @member.thread_id || "pending" %></dd></div>
                  <div><dt>Session</dt><dd class="mono"><%= @member.latest_session_id || "pending" %></dd></div>
                  <div><dt>Workspace</dt><dd class="mono"><%= @member.workspace || "pending" %></dd></div>
                </dl>
              </details>
            </aside>

            <section class="team-events" aria-labelledby="team-event-log-title">
              <div class="team-events-heading">
                <div>
                  <h2 id="team-event-log-title">Member event log</h2>
                  <p>Latest bounded messages between team members.</p>
                </div>
                <span class="log-count">
                  <span
                    class="log-follow-state"
                    data-follow-state="following"
                    role="status"
                    aria-live="polite"
                  >Following</span>
                  <span class="numeric"><%= length(@team.events) %> events</span>
                </span>
              </div>

              <ol
                id="team-event-log"
                class="team-event-log"
                role="log"
                aria-labelledby="team-event-log-title"
                aria-live="off"
                tabindex="0"
                data-follow-log
              >
                <li
                  :for={event <- @team.events}
                  class={[
                    "team-event",
                    team_event_related?(event, @selected_member_id) && "team-event-related"
                  ]}
                  data-event-id={event.id}
                >
                  <.team_event_time value={event.timestamp} />
                  <span class="team-event-route">
                    <span class="team-event-sender"><%= member_label(@team, event.sender) %></span>
                    <span class="team-event-arrow" aria-label="to">→</span>
                    <span class="team-event-recipient"><%= member_label(@team, event.recipient) %></span>
                  </span>
                  <span class="team-event-content">
                    <span class="team-event-kind"><%= event.kind %></span>
                    <span class="team-event-message"><%= event.message %></span>
                  </span>
                </li>
              </ol>
              <p :if={@team.events == []} class="log-empty">
                No member events are available for this team yet.
              </p>
              <p
                :if={@team.events != []}
                class="visually-hidden"
                aria-live="polite"
                aria-atomic="true"
              >Latest team activity: <%= List.last(@team.events).message %></p>
            </section>
          </section>
      <% end %>
    </div>
    """
  end

  defp dashboard_loading(assigns) do
    ~H"""
    <section class="dashboard-message dashboard-loading" role="status" aria-live="polite">
      <span class="loading-mark" aria-hidden="true"></span>
      <div>
        <h2>Loading runtime status</h2>
        <p>Connecting to the current Symphony runtime.</p>
      </div>
    </section>
    """
  end

  defp dashboard_error(assigns) do
    ~H"""
    <section class="dashboard-message dashboard-error" role="alert">
      <h2>Snapshot unavailable</h2>
      <p><strong><%= @error.code %>:</strong> <%= @error.message %></p>
      <p>Symphony retries automatically. Check the runtime process if this state persists.</p>
    </section>
    """
  end

  defp operations_page(assigns) do
    ~H"""
    <div class="page-content operations-page">
      <header class="dashboard-header">
        <div>
          <h1>Operations Dashboard</h1>
          <p class="header-copy">Live agent work, attention states, and streaming session output.</p>
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
        <% @agents == [] and payload_teams(@payload) == [] and is_nil(@selected_agent) -> %>
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

          <section
            :if={@payload.teams != []}
            class="team-preview"
            aria-labelledby="team-preview-title"
          >
            <div class="panel-heading">
              <h2 id="team-preview-title">Team activity</h2>
              <span class="agent-total numeric"><%= length(@payload.teams) %></span>
            </div>
            <div class="team-preview-list">
              <.team_preview_row :for={team <- @payload.teams} team={team} />
            </div>
          </section>

          <div :if={@agents != [] or not is_nil(@selected_agent)} class="agent-workspace">
            <aside class="agent-overview" aria-labelledby="agent-overview-title">
              <div class="panel-heading">
                <div>
                  <h2 id="agent-overview-title">Agents</h2>
                </div>
                <span class="agent-total numeric"><%= length(@agents) %></span>
              </div>

              <div class="agent-list" aria-label="Choose an agent">
                <div
                  :for={agent <- @agents}
                  class={[
                    "agent-row-wrap",
                    @selected_agent_id == agent.id && "agent-row-selected"
                  ]}
                  data-agent-status={effective_status(agent, @now)}
                >
                  <% issue_resource = issue_resource(agent.issue_url, agent.issue_identifier) %>
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
                      <%= activity_time_prefix(agent, @now) %>
                      <.timestamp
                        value={activity_timestamp(agent, @now)}
                        fallback={activity_time_fallback(agent, @now)}
                      />
                    </span>
                  </button>
                  <a
                    :if={issue_resource}
                    class="agent-row-resource-link"
                    href={issue_resource.href}
                    target="_blank"
                    rel="noopener noreferrer"
                    aria-label={issue_resource.label}
                  ><%= issue_resource.label %></a>
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
    </div>
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
      |> assign(:issue_resource, issue_resource(assigns.agent.issue_url, assigns.agent.issue_identifier))
      |> assign(:pull_request, pull_request(assigns.agent[:pull_request_url]))

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
        <nav class="resource-links" aria-label="Agent resources">
          <a
            :if={@issue_resource}
            class="resource-link"
            href={@issue_resource.href}
            target="_blank"
            rel="noopener noreferrer"
            aria-label={@issue_resource.label}
          >
            <span aria-hidden="true"><%= @issue_resource.source %></span>
            <strong><%= @agent.issue_identifier %></strong>
          </a>
          <a
            :if={@pull_request}
            class="resource-link"
            href={@pull_request.href}
            target="_blank"
            rel="noopener noreferrer"
            aria-label={@pull_request.label}
          >
            <span aria-hidden="true">GitHub</span>
            <strong><%= @pull_request.label %></strong>
          </a>
        </nav>
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
            <.timestamp value={@agent.activity_at || @agent.relevant_at} />
          </p>
        </section>

        <%= if @agent.status == "retrying" do %>
          <div class="attention-note attention-note-retry" role="status" aria-live="polite">
            <strong>Retry attempt <%= @agent.attempt || "n/a" %></strong>
            <p><%= @agent.reason || "The last attempt did not complete." %></p>
            <dl class="inline-facts">
              <div><dt>Next retry</dt><dd><.timestamp value={@agent.due_at} fallback="Not scheduled" /></dd></div>
              <div><dt>Next action</dt><dd><%= @agent.next_action %></dd></div>
            </dl>
          </div>
        <% end %>

        <%= if @agent.status == "blocked" do %>
          <div class="attention-note attention-note-blocked" role="alert">
            <strong>Approval or input needed</strong>
            <p><%= @agent.reason || "The agent is waiting for operator input." %></p>
            <dl class="inline-facts">
              <div><dt>Blocked at</dt><dd><.timestamp value={@agent.relevant_at} fallback="Not reported" /></dd></div>
              <div><dt>Next action</dt><dd><%= @agent.next_action %></dd></div>
            </dl>
          </div>
        <% end %>
      <% end %>

      <section class="log-section" aria-labelledby="log-title">
        <div class="panel-heading log-heading">
          <div>
            <p class="panel-kicker">Selected session</p>
            <h3 id="log-title">Live activity</h3>
            <p class="log-description">Latest verified actions from this agent.</p>
          </div>
          <span class="log-count">
            <span
              id="log-follow-state"
              class="log-follow-state"
              data-log-follow-state="following"
              data-follow-state="following"
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
          data-follow-log
        >
          <li :for={entry <- @agent.log_tail} class="log-line">
            <time class="log-time" datetime={entry.at} title={entry.at}>
              <%= log_time(entry.at) %>
            </time>
            <span class="log-event"><%= log_event(entry.event) %></span>
            <span class="log-message"><%= entry.message %></span>
          </li>
        </ol>
        <p :if={@agent.log_tail == []} class="log-empty">
          No audit output is available for this session yet.
        </p>
        <p
          :if={@agent.log_tail != []}
          class="visually-hidden"
          aria-live="polite"
          aria-atomic="true"
        >
          Latest activity: <%= List.last(@agent.log_tail).message %>
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
          <dd><.timestamp value={@agent.activity_at} fallback="n/a" /></dd>
        </div>
      </dl>

      <details id="session-workspace-disclosure" class="detail-disclosure">
        <summary id="session-workspace-summary">Session and workspace</summary>
        <dl class="disclosure-facts">
          <div>
            <dt>Session ID</dt>
            <dd>
              <span class="mono"><%= @agent.session_id || "n/a" %></span>
              <button
                :if={@agent.session_id}
                id="copy-session-id"
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

      <details id="audit-diagnostics-disclosure" class="detail-disclosure">
        <summary id="audit-diagnostics-summary">Audit and diagnostics</summary>
        <dl class="disclosure-facts">
          <div>
            <dt>Audit</dt>
            <dd>
              <span class="mono"><%= @agent.audit_path || "n/a" %></span>
              <button
                :if={@agent.audit_path}
                id="copy-audit-path"
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
          <div :if={@agent.audit_summary}>
            <dt>Verification profile</dt>
            <dd><strong><%= @agent.audit_summary.verification_profile || "n/a" %></strong></dd>
          </div>
          <div :if={@agent.audit_summary}>
            <dt>Context cache</dt>
            <dd>
              <%= @agent.audit_summary.context_cache_hits %> hits ·
              <%= @agent.audit_summary.context_cache_misses %> misses
            </dd>
          </div>
          <div :if={@agent.audit_summary}>
            <dt>Proof cache</dt>
            <dd>
              <%= @agent.audit_summary.proof_cache_hits %> hits ·
              <%= @agent.audit_summary.proof_cache_misses %> misses
            </dd>
          </div>
          <div :if={@agent.audit_summary && @agent.audit_summary.slowest_phase}>
            <dt>Slowest phase</dt>
            <dd>
              <strong><%= @agent.audit_summary.slowest_phase %></strong>
              · <%= format_duration_ms(@agent.audit_summary.slowest_phase_duration_ms) %>
            </dd>
          </div>
          <div :if={@agent.audit_summary && @agent.audit_summary.budget_overrun_count > 0}>
            <dt>Budget overruns</dt>
            <dd>
              <%= @agent.audit_summary.budget_overrun_count %>
              · max <%= format_duration_ms(@agent.audit_summary.max_budget_overrun_ms) %>
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
    |> refresh_team_selection()
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
  defp dashboard_state(%{teams: []}, []), do: "empty"
  defp dashboard_state(_payload, _agents), do: "ready"

  defp refresh_team_selection(%{assigns: %{payload: nil}} = socket), do: socket

  defp refresh_team_selection(%{assigns: %{live_action: :team}} = socket) do
    team =
      socket.assigns.payload
      |> payload_teams()
      |> Enum.find(&(&1.request_id == socket.assigns.request_id))

    selected_member_id =
      case team do
        %{agents: agents} ->
          if Enum.any?(agents, &(&1.agent_id == socket.assigns.selected_member_id)) do
            socket.assigns.selected_member_id
          else
            nil
          end

        _other ->
          nil
      end

    selected_member =
      case team do
        %{agents: agents} -> Enum.find(agents, &(&1.agent_id == selected_member_id))
        _other -> nil
      end

    socket
    |> assign(:selected_team, team)
    |> assign(:selected_member_id, selected_member_id)
    |> assign(:selected_member, selected_member)
  end

  defp refresh_team_selection(socket) do
    socket
    |> assign(:selected_team, nil)
    |> assign(:selected_member_id, nil)
    |> assign(:selected_member, nil)
  end

  defp payload_teams(%{teams: teams}) when is_list(teams), do: teams
  defp payload_teams(_payload), do: []

  defp reading_context(%{live_action: :team} = assigns) do
    "team:#{assigns.request_id}"
  end

  defp reading_context(%{live_action: :teams}), do: "teams"

  defp reading_context(assigns) do
    "operations:#{assigns.selected_agent_id}"
  end

  defp team_preview_row(assigns) do
    assigns =
      assigns
      |> assign(:attention?, team_needs_attention?(assigns.team))
      |> assign(:summary, team_summary(assigns.team))

    ~H"""
    <article class="team-preview-row" data-team-request={@team.request_id}>
      <div class="team-preview-identity">
        <span class={if(@attention?, do: "team-state-attention", else: "team-state-active")}>
          <span class="team-state-mark" aria-hidden="true"></span>
          <%= if @attention?, do: "Needs attention", else: "Active" %>
        </span>
        <h3><%= team_label(@team) %></h3>
      </div>
      <p class="team-preview-summary"><%= @summary %></p>
      <p :if={@team.latest_event} class="team-preview-event">
        <span class="team-event-route">
          <%= member_label(@team, @team.latest_event.sender) %>
          <span aria-hidden="true">→</span>
          <%= member_label(@team, @team.latest_event.recipient) %>
        </span>
        <span><%= @team.latest_event.message %></span>
      </p>
      <.link class="team-preview-action" navigate={"/teams/#{@team.request_id}"}>
        <%= if @attention?, do: "Review blocker", else: "Open team" %>
        <span aria-hidden="true">→</span>
      </.link>
    </article>
    """
  end

  defp team_needs_attention?(team) do
    Enum.any?(team.agents, &(&1.status in ["blocked", "failed"]))
  end

  defp team_summary(team) do
    statuses = Enum.frequencies_by(team.agents, &team_member_status_label(&1.status))

    status_summary =
      ["Active", "Waiting", "Blocked", "Completed", "Failed"]
      |> Enum.flat_map(fn status ->
        case Map.get(statuses, status, 0) do
          0 -> []
          count -> ["#{count} #{String.downcase(status)}"]
        end
      end)
      |> Enum.join(" · ")

    member_summary = "#{length(team.agents)} #{pluralize(length(team.agents), "member")}"
    if status_summary == "", do: member_summary, else: member_summary <> " · " <> status_summary
  end

  defp team_label(%{identifier: identifier, request_id: request_id}) do
    identifier || request_id || "Team request"
  end

  defp member_label(team, agent_id) do
    case Enum.find(team.agents, &(&1.agent_id == agent_id)) do
      nil -> agent_id || "Unknown member"
      member -> member_display_name(member)
    end
  end

  defp member_display_name(%{role: "coordinator"}), do: "Coordinator"

  defp member_display_name(%{repository: repository}) when is_binary(repository) do
    repository
    |> String.replace(~r/[-_]+/, " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp member_display_name(%{agent_id: agent_id}) when is_binary(agent_id), do: agent_id
  defp member_display_name(_member), do: "Team member"

  defp member_activity(%{latest_event: %{message: message}}) when is_binary(message), do: message
  defp member_activity(%{status: "completed"}), do: "Work is complete and ready for review."
  defp member_activity(%{status: "blocked"}), do: "Waiting for input before work can continue."
  defp member_activity(%{status: "failed"}), do: "Work stopped after an error."
  defp member_activity(%{status: "waiting"}), do: "Waiting for the next team handoff."
  defp member_activity(_member), do: "Working on the current team request."

  defp team_member_status_class(status) do
    ["team-member-status", "team-member-status-#{status || "unknown"}"]
  end

  defp team_member_status_label("running"), do: "Active"
  defp team_member_status_label("active"), do: "Active"
  defp team_member_status_label("waiting"), do: "Waiting"
  defp team_member_status_label("blocked"), do: "Blocked"
  defp team_member_status_label("completed"), do: "Completed"
  defp team_member_status_label("failed"), do: "Failed"
  defp team_member_status_label(_status), do: "Pending"

  defp team_event_related?(_event, nil), do: false

  defp team_event_related?(event, selected_member_id) do
    event.sender == selected_member_id or event.recipient == selected_member_id
  end

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

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

  defp issue_resource(url, issue_identifier) do
    case external_issue_url(url) do
      nil ->
        nil

      href ->
        source = if URI.parse(href).host == "linear.app", do: "Linear", else: "Issue"
        %{href: href, label: "#{source} #{issue_identifier}", source: source}
    end
  end

  defp pull_request(url) when is_binary(url) do
    case GitHubRepository.pull_request_url(url) do
      {:ok, %{number: number}} -> %{href: url, label: "PR ##{number}"}
      {:error, :invalid_pull_request_url} -> nil
    end
  end

  defp pull_request(_url), do: nil

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

  defp activity_time_prefix(agent, now) do
    case effective_status(agent, now) do
      "retrying" -> "Next retry "
      "blocked" -> "Blocked "
      "stale" -> "Last update "
      _ -> "Updated "
    end
  end

  defp activity_timestamp(agent, now) do
    case effective_status(agent, now) do
      "retrying" -> agent.due_at
      "blocked" -> agent.relevant_at
      _ -> agent.activity_at || agent.relevant_at
    end
  end

  defp activity_time_fallback(agent, now) do
    case effective_status(agent, now) do
      "retrying" -> "not scheduled"
      "blocked" -> "at unknown time"
      _ -> "Timestamp not reported"
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

  defp format_duration_ms(milliseconds) when is_integer(milliseconds) and milliseconds >= 60_000,
    do: "#{Float.round(milliseconds / 60_000, 1)}m"

  defp format_duration_ms(milliseconds) when is_integer(milliseconds) and milliseconds >= 1_000,
    do: "#{Float.round(milliseconds / 1_000, 1)}s"

  defp format_duration_ms(milliseconds) when is_integer(milliseconds),
    do: "#{milliseconds}ms"

  defp format_duration_ms(_milliseconds), do: "n/a"

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

  attr(:value, :any, required: true)
  attr(:fallback, :string, default: "Timestamp not reported")

  defp timestamp(assigns) do
    assigns =
      assigns
      |> assign(:iso, timestamp_iso(assigns.value))
      |> assign(:label, format_timestamp(assigns.value))

    ~H"""
    <%= if @iso && @label do %>
      <time datetime={@iso} title={@iso}><%= @label %></time>
    <% else %>
      <%= @fallback %>
    <% end %>
    """
  end

  attr(:value, :any, required: true)

  defp team_event_time(assigns) do
    assigns =
      assigns
      |> assign(:iso, timestamp_iso(assigns.value))
      |> assign(:label, format_team_event_timestamp(assigns.value))

    ~H"""
    <%= if @iso && @label do %>
      <time class="team-event-time" datetime={@iso} data-local-timestamp title={@iso}><%= @label %></time>
    <% else %>
      <span class="team-event-time">Time unavailable</span>
    <% end %>
    """
  end

  defp timestamp_iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp timestamp_iso(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      _ -> nil
    end
  end

  defp timestamp_iso(_timestamp), do: nil

  defp format_timestamp(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%d %b %Y · %H:%M UTC")

  defp format_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> format_timestamp(datetime)
      _ -> nil
    end
  end

  defp format_timestamp(_timestamp), do: nil

  defp format_team_event_timestamp(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%d %b · %H:%M:%S UTC")

  defp format_team_event_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> format_team_event_timestamp(datetime)
      _ -> nil
    end
  end

  defp format_team_event_timestamp(_timestamp), do: nil

  defp log_time(nil), do: "--"

  defp log_time(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} ->
        Calendar.strftime(datetime, "%d %b · %H:%M UTC")

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
