unless Mix.env() == :test do
  raise "dashboard visual fixture is test-only"
end

defmodule SymphonyElixir.DashboardVisualFixture.Orchestrator do
  use GenServer

  @name __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: @name)
  def set_state(state), do: GenServer.call(@name, {:set_state, state})
  def publish_update, do: GenServer.call(@name, :publish_update)

  @impl true
  def init(:ok) do
    audit_paths = %{
      running: write_audit_file!("running", "Streaming implementation output"),
      retrying: write_audit_file!("retrying", "Previous attempt output"),
      blocked: write_audit_file!("blocked", "Operator input context")
    }

    {:ok, %{mode: :mixed, revision: 0, audit_paths: audit_paths}}
  end

  @impl true
  def handle_call(:snapshot, _from, %{mode: :error} = state), do: {:reply, :unavailable, state}

  def handle_call(:snapshot, _from, %{mode: :loading} = state) do
    Process.sleep(1_200)
    {:reply, snapshot(:mixed, state), state}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, snapshot(state.mode, state), state}

  def handle_call(:request_refresh, _from, state) do
    {:reply, %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["fixture"]}, state}
  end

  def handle_call({:set_state, mode}, _from, state) do
    next_state = %{state | mode: mode}
    :ok = SymphonyElixirWeb.ObservabilityPubSub.broadcast_update()
    {:reply, :ok, next_state}
  end

  def handle_call(:publish_update, _from, state) do
    next_state = %{state | revision: state.revision + 1}

    File.write!(
      state.audit_paths.running,
      Jason.encode!(%{
        "event" => "agent_message",
        "timestamp" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "detail" => "Live output revision #{next_state.revision}: completed bounded dashboard update"
      }) <> "\n",
      [:append]
    )

    :ok = SymphonyElixirWeb.ObservabilityPubSub.broadcast_update()
    {:reply, :ok, next_state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.audit_paths, fn {_status, path} -> File.rm(path) end)
    :ok
  end

  defp write_audit_file!(status, message) do
    path =
      Path.join(
        System.tmp_dir!(),
        "symphony-dashboard-visual-#{status}-#{System.unique_integer([:positive])}.jsonl"
      )

    events =
      Enum.map(1..60, fn index ->
        Jason.encode!(%{
          "event" => "agent_message",
          "timestamp" =>
            DateTime.utc_now()
            |> DateTime.add(index - 90, :second)
            |> DateTime.truncate(:second)
            |> DateTime.to_iso8601(),
          "detail" => "#{message} #{index}"
        })
      end)

    events =
      if status == "running" do
        events ++
          [
            Jason.encode!(%{
              "event" => "execution_plan_approved",
              "timestamp" =>
                DateTime.utc_now()
                |> DateTime.add(-24, :second)
                |> DateTime.truncate(:second)
                |> DateTime.to_iso8601(),
              "verification_profile" => "Full"
            }),
            Jason.encode!(%{
              "event" => "proof_completed",
              "timestamp" =>
                DateTime.utc_now()
                |> DateTime.add(-23, :second)
                |> DateTime.truncate(:second)
                |> DateTime.to_iso8601(),
              "cache_status" => "hit"
            }),
            Jason.encode!(%{
              "event" => "phase_timing",
              "timestamp" =>
                DateTime.utc_now()
                |> DateTime.add(-22, :second)
                |> DateTime.truncate(:second)
                |> DateTime.to_iso8601(),
              "phase" => "planning",
              "duration_ms" => 12_500,
              "budget_overrun_ms" => 2_500
            }),
            Jason.encode!(%{
              "event" => "pull_request_published",
              "timestamp" =>
                DateTime.utc_now()
                |> DateTime.add(-20, :second)
                |> DateTime.truncate(:second)
                |> DateTime.to_iso8601(),
              "detail" => "Published pull request for review",
              "pull_request_url" => "https://github.com/bjornjee/symphony/pull/25"
            })
          ]
      else
        events
      end

    File.write!(path, Enum.join(events, "\n") <> "\n")
    path
  end

  defp snapshot(:empty, _state), do: empty_snapshot()

  defp snapshot(:stale, state) do
    stale_at = DateTime.add(DateTime.utc_now(), -600, :second)

    %{
      empty_snapshot()
      | running: [
          running_entry(state,
            issue_id: "issue-stale",
            identifier: "PIN-STALE",
            message: "Waiting for a new agent update",
            timestamp: stale_at
          )
        ],
        codex_totals: %{input_tokens: 1_300, output_tokens: 144, total_tokens: 1_444, seconds_running: 610.0}
    }
  end

  defp snapshot(:transitioned, state) do
    mixed = snapshot(:mixed, state)

    transitioned = %{
      issue_id: "issue-running",
      identifier: "PIN-RUNNING",
      issue_url: "https://linear.app/pinkgu/issue/PIN-RUNNING/dashboard",
      attempt: 2,
      due_in_ms: 30_000,
      error: "Temporary upstream failure; retry scheduled",
      worker_host: "fixture-worker",
      workspace_path: "/tmp/symphony/PIN-RUNNING",
      audit_path: "/tmp/symphony/PIN-RUNNING/.symphony/run-audit.md",
      audit_events_path: state.audit_paths.running,
      capability_diagnostics: nil
    }

    %{mixed | running: [], retrying: [transitioned | mixed.retrying]}
  end

  defp snapshot(:mixed, state) do
    now = DateTime.utc_now()

    %{
      running: [
        running_entry(state,
          issue_id: "issue-running",
          identifier: "PIN-RUNNING",
          message: "Implementing the selected-session live log",
          timestamp: now
        )
      ],
      retrying: [
        %{
          issue_id: "issue-retrying",
          identifier: "PIN-RETRYING",
          issue_url: "https://linear.app/pinkgu/issue/PIN-RETRYING/dashboard",
          attempt: 3,
          due_in_ms: 30_000,
          error: "Upstream rate limit interrupted the previous turn",
          worker_host: "fixture-worker",
          workspace_path: "/tmp/symphony/PIN-RETRYING",
          audit_path: nil,
          audit_events_path: state.audit_paths.retrying,
          capability_diagnostics: nil
        }
      ],
      blocked: [
        %{
          issue_id: "issue-blocked",
          identifier: "PIN-BLOCKED",
          issue_url: "https://linear.app/pinkgu/issue/PIN-BLOCKED/dashboard",
          state: "In Progress",
          error: "Approval is required before the agent can continue",
          worker_host: "fixture-worker",
          workspace_path: "/tmp/symphony/PIN-BLOCKED",
          audit_path: "/tmp/symphony/PIN-BLOCKED/.symphony/run-audit.md",
          audit_events_path: state.audit_paths.blocked,
          capability_diagnostics: nil,
          session_id: "fixture-blocked-session",
          blocked_at: DateTime.add(now, -45, :second),
          last_codex_event: :turn_input_required,
          last_codex_message: "Waiting for operator approval",
          last_codex_timestamp: DateTime.add(now, -45, :second)
        }
      ],
      codex_totals: %{
        input_tokens: 42_100 + state.revision,
        output_tokens: 3_201,
        total_tokens: 45_301 + state.revision,
        seconds_running: 482.0
      },
      rate_limits: %{"primary" => %{"remaining" => 72}}
    }
  end

  defp empty_snapshot do
    %{
      running: [],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0.0},
      rate_limits: nil
    }
  end

  defp running_entry(state, opts) do
    now = DateTime.utc_now()

    %{
      issue_id: Keyword.fetch!(opts, :issue_id),
      identifier: Keyword.fetch!(opts, :identifier),
      issue_url: "https://linear.app/pinkgu/issue/#{Keyword.fetch!(opts, :identifier)}/dashboard",
      state: "In Progress",
      session_id: "fixture-running-session",
      turn_count: 8,
      codex_app_server_pid: nil,
      last_codex_message: "#{Keyword.fetch!(opts, :message)} · revision #{state.revision}",
      last_codex_timestamp: Keyword.fetch!(opts, :timestamp),
      last_codex_event: :notification,
      worker_host: "fixture-worker",
      workspace_path: "/tmp/symphony/#{Keyword.fetch!(opts, :identifier)}",
      codex_input_tokens: 42_100 + state.revision,
      codex_output_tokens: 3_201,
      codex_total_tokens: 45_301 + state.revision,
      audit_path: "/tmp/symphony/#{Keyword.fetch!(opts, :identifier)}/.symphony/run-audit.md",
      audit_events_path: state.audit_paths.running,
      capability_diagnostics: %{
        browser_path: %{
          selected: "playwright_headless",
          provenance: "test_fixture",
          code: "ready",
          action: "Use deterministic headless Playwright."
        }
      },
      started_at: DateTime.add(now, -482, :second)
    }
  end
end

defmodule SymphonyElixir.DashboardVisualFixture.ControlPlug do
  use Plug.Router

  alias SymphonyElixir.DashboardVisualFixture.Orchestrator

  plug(:match)
  plug(:dispatch)

  get "/health" do
    send_resp(conn, 200, "ready")
  end

  post "/state/:state" do
    modes = %{
      "mixed" => :mixed,
      "transitioned" => :transitioned,
      "stale" => :stale,
      "empty" => :empty,
      "loading" => :loading,
      "error" => :error
    }

    case Map.fetch(modes, state) do
      {:ok, mode} ->
        :ok = Orchestrator.set_state(mode)
        send_resp(conn, 204, "")

      :error ->
        send_resp(conn, 404, "unknown fixture state")
    end
  end

  post "/update" do
    :ok = Orchestrator.publish_update()
    send_resp(conn, 204, "")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end

port =
  System.get_env("DASHBOARD_FIXTURE_PORT", "43127")
  |> String.to_integer()

control_port = port + 1

{:ok, _started} = Application.ensure_all_started(:bandit)
{:ok, _pubsub_started} = Application.ensure_all_started(:phoenix_pubsub)

{:ok, _pubsub_supervisor} =
  Supervisor.start_link(
    [{Phoenix.PubSub, name: SymphonyElixir.PubSub}],
    strategy: :one_for_one
  )

{:ok, _orchestrator} = SymphonyElixir.DashboardVisualFixture.Orchestrator.start_link([])

{:ok, _endpoint} =
  SymphonyElixir.HttpServer.start_link(
    host: "127.0.0.1",
    port: port,
    orchestrator: SymphonyElixir.DashboardVisualFixture.Orchestrator,
    snapshot_timeout_ms: 3_000
  )

{:ok, _control} =
  Bandit.start_link(
    plug: SymphonyElixir.DashboardVisualFixture.ControlPlug,
    scheme: :http,
    ip: {127, 0, 0, 1},
    port: control_port
  )

IO.puts("dashboard visual fixture ready on 127.0.0.1:#{port} (control #{control_port})")
Process.sleep(:infinity)
