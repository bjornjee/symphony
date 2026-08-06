defmodule SymphonyElixir.TeamBus do
  @moduledoc """
  Bounded request-local event routing for Team Mode agents.
  """

  use GenServer

  @max_events 100
  @max_message_bytes 4_096
  @kinds ~w(update handoff check blocker)
  @terminal_statuses ~w(completed failed cancelled)

  @type event :: %{
          id: pos_integer(),
          request_id: String.t(),
          sender: String.t(),
          recipient: String.t(),
          kind: String.t(),
          message: String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec register(pid(), String.t(), map()) :: :ok | {:error, term()}
  def register(server, agent_id, attrs) when is_pid(server) and is_binary(agent_id) and is_map(attrs) do
    GenServer.call(server, {:register, agent_id, attrs})
  end

  @spec mark_status(pid(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def mark_status(server, agent_id, status, attrs \\ %{})
      when is_pid(server) and is_binary(agent_id) and is_binary(status) and is_map(attrs) do
    GenServer.call(server, {:mark_status, agent_id, status, attrs})
  end

  @spec send_event(pid(), String.t(), String.t(), String.t() | atom(), String.t()) ::
          {:ok, event()} | {:error, term()}
  def send_event(server, sender, recipient, kind, message)
      when is_pid(server) and is_binary(sender) and is_binary(recipient) and is_binary(message) do
    GenServer.call(server, {:send_event, sender, recipient, to_string(kind), message})
  end

  @spec snapshot(pid()) :: map()
  def snapshot(server) when is_pid(server), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    agents = Keyword.fetch!(opts, :agents)

    agent_states =
      Map.new(agents, fn agent ->
        agent_id = Map.fetch!(agent, :agent_id)

        {agent_id,
         %{
           agent_id: agent_id,
           role: Map.fetch!(agent, :role),
           repository: Map.get(agent, :repository),
           thread_id: nil,
           latest_session_id: nil,
           workspace: nil,
           status: "queued",
           pr_url: nil,
           latest_event: nil,
           delivered_event_id: 0,
           steer: nil
         }}
      end)

    {:ok, %{request_id: request_id, agents: agent_states, events: [], next_event_id: 1}}
  end

  @impl true
  def handle_call({:register, agent_id, attrs}, _from, state) do
    case Map.fetch(state.agents, agent_id) do
      :error ->
        {:reply, {:error, :unknown_agent}, state}

      {:ok, agent} ->
        updated =
          agent
          |> Map.merge(Map.take(attrs, [:thread_id, :latest_session_id, :workspace, :pr_url, :steer]))
          |> Map.put(:status, "active")

        case deliver_queued(state.events, updated) do
          {:ok, delivered_event_id} ->
            updated = %{updated | delivered_event_id: delivered_event_id}
            {:reply, :ok, put_in(state, [:agents, agent_id], updated)}

          {:error, reason} ->
            {:reply, {:error, {:steer_failed, reason}}, state}
        end
    end
  end

  def handle_call({:mark_status, agent_id, status, attrs}, _from, state) do
    case Map.fetch(state.agents, agent_id) do
      :error ->
        {:reply, {:error, :unknown_agent}, state}

      {:ok, agent} ->
        updated =
          agent
          |> Map.merge(Map.take(attrs, [:thread_id, :latest_session_id, :workspace, :pr_url, :latest_event]))
          |> Map.put(:status, status)
          |> maybe_clear_steer(status)

        {:reply, :ok, put_in(state, [:agents, agent_id], updated)}
    end
  end

  def handle_call({:send_event, sender, recipient, kind, message}, _from, state) do
    with :ok <- validate_sender(state, sender),
         {:ok, recipient_agent} <- validate_recipient(state, recipient),
         :ok <- validate_event(kind, message) do
      event = %{
        id: state.next_event_id,
        request_id: state.request_id,
        sender: sender,
        recipient: recipient,
        kind: kind,
        message: message
      }

      case maybe_deliver(recipient_agent, event) do
        :ok ->
          {:reply, {:ok, event}, record_event(state, sender, recipient, event)}

        {:error, reason} ->
          {:reply, {:error, {:steer_failed, reason}}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    agents =
      Map.new(state.agents, fn {agent_id, agent} ->
        {agent_id, Map.drop(agent, [:steer, :delivered_event_id])}
      end)

    {:reply,
     %{
       request_id: state.request_id,
       agents: agents,
       events: state.events,
       next_event_id: state.next_event_id
     }, state}
  end

  defp validate_sender(state, sender) do
    if Map.has_key?(state.agents, sender), do: :ok, else: {:error, :unknown_sender}
  end

  defp validate_recipient(state, recipient) do
    case Map.fetch(state.agents, recipient) do
      :error -> {:error, :unknown_recipient}
      {:ok, %{status: status}} when status in @terminal_statuses -> {:error, :recipient_completed}
      {:ok, agent} -> {:ok, agent}
    end
  end

  defp validate_event(kind, message) do
    cond do
      kind not in @kinds -> {:error, :invalid_kind}
      String.trim(message) == "" -> {:error, :empty_message}
      byte_size(message) > @max_message_bytes -> {:error, :message_too_large}
      true -> :ok
    end
  end

  defp record_event(state, sender, recipient, event) do
    events = Enum.take(state.events ++ [event], -@max_events)

    agents =
      state.agents
      |> update_in([sender], &Map.put(&1, :latest_event, event))
      |> update_in([recipient], fn agent ->
        agent
        |> Map.put(:latest_event, event)
        |> maybe_mark_delivered(event)
      end)

    %{state | events: events, agents: agents, next_event_id: event.id + 1}
  end

  defp maybe_deliver(%{status: "active", steer: steer}, event) when is_function(steer, 1) do
    case steer.(format_for_delivery(event)) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_steer_result, other}}
    end
  end

  defp maybe_deliver(_agent, _event), do: :ok

  defp deliver_queued(events, %{agent_id: agent_id, delivered_event_id: delivered_event_id} = agent) do
    events
    |> Enum.filter(&(&1.recipient == agent_id and &1.id > delivered_event_id))
    |> Enum.reduce_while({:ok, delivered_event_id}, fn event, {:ok, _last_id} ->
      case maybe_deliver(agent, event) do
        :ok -> {:cont, {:ok, event.id}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp format_for_delivery(event) do
    "[team event #{event.id} from #{event.sender} · #{event.kind}]\n#{event.message}"
  end

  defp maybe_mark_delivered(%{status: "active"} = agent, event), do: %{agent | delivered_event_id: event.id}
  defp maybe_mark_delivered(agent, _event), do: agent

  defp maybe_clear_steer(agent, "active"), do: agent
  defp maybe_clear_steer(agent, _status), do: %{agent | steer: nil}
end
