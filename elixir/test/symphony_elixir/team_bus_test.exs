defmodule SymphonyElixir.TeamBusTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TeamBus

  setup do
    agents = [
      %{agent_id: "coordinator", role: "coordinator", repository: nil},
      %{agent_id: "repo:application", role: "implementer", repository: "application"},
      %{agent_id: "repo:infrastructure", role: "implementer", repository: "infrastructure"}
    ]

    start_supervised!({TeamBus, request_id: "PIN-42", agents: agents})
    |> then(&%{bus: &1})
  end

  test "queues messages before a recipient starts and steers them after registration", %{bus: bus} do
    assert {:ok, %{id: 1}} =
             TeamBus.send_event(bus, "coordinator", "repo:application", "handoff", "Use config v2.")

    test_pid = self()

    assert :ok =
             TeamBus.register(bus, "repo:application", %{
               thread_id: "thread-app",
               latest_session_id: "thread-app-turn-1",
               workspace: "/workspaces/PIN-42/application",
               steer: fn message ->
                 send(test_pid, {:steered, message})
                 :ok
               end
             })

    assert_received {:steered, "[team event 1 from coordinator · handoff]\nUse config v2."}

    snapshot = TeamBus.snapshot(bus)
    assert snapshot.request_id == "PIN-42"
    assert snapshot.next_event_id == 2
    assert length(snapshot.events) == 1
    assert snapshot.agents["repo:application"].status == "active"
  end

  test "steers active recipients immediately and rejects completed or unknown recipients", %{bus: bus} do
    test_pid = self()

    assert :ok =
             TeamBus.register(bus, "repo:infrastructure", %{
               thread_id: "thread-infra",
               latest_session_id: "thread-infra-turn-1",
               workspace: "/workspaces/PIN-42/infrastructure",
               steer: fn message ->
                 send(test_pid, {:steered, message})
                 :ok
               end
             })

    assert {:ok, %{id: 1}} =
             TeamBus.send_event(bus, "repo:application", "repo:infrastructure", :check, "Is the output ready?")

    assert_received {:steered, "[team event 1 from repo:application · check]\nIs the output ready?"}

    assert :ok = TeamBus.mark_status(bus, "repo:infrastructure", "completed")

    assert {:error, :recipient_completed} =
             TeamBus.send_event(bus, "coordinator", "repo:infrastructure", "update", "late")

    assert {:error, :unknown_recipient} =
             TeamBus.send_event(bus, "coordinator", "repo:unknown", "update", "unknown")
  end

  test "bounds message bytes and retains only the latest 100 events", %{bus: bus} do
    assert {:error, :message_too_large} =
             TeamBus.send_event(bus, "coordinator", "repo:application", "update", String.duplicate("x", 4_097))

    for index <- 1..105 do
      assert {:ok, %{id: ^index}} =
               TeamBus.send_event(bus, "coordinator", "repo:application", "update", "event #{index}")
    end

    snapshot = TeamBus.snapshot(bus)
    assert Enum.map(snapshot.events, & &1.id) == Enum.to_list(6..105)
    assert snapshot.next_event_id == 106
  end

  test "rejects invalid senders, messages, registrations, and steering failures", %{bus: bus} do
    assert {:error, :unknown_agent} = TeamBus.register(bus, "repo:unknown", %{})
    assert {:error, :unknown_agent} = TeamBus.mark_status(bus, "repo:unknown", "completed")

    assert {:error, :unknown_sender} =
             TeamBus.send_event(bus, "repo:unknown", "coordinator", "update", "message")

    assert {:error, :invalid_kind} =
             TeamBus.send_event(bus, "coordinator", "repo:application", "invalid", "message")

    assert {:error, :empty_message} =
             TeamBus.send_event(bus, "coordinator", "repo:application", "update", "   ")

    assert {:ok, _event} =
             TeamBus.send_event(bus, "coordinator", "repo:application", "update", "queued")

    assert {:error, {:steer_failed, :not_ready}} =
             TeamBus.register(bus, "repo:application", %{
               steer: fn _message -> {:error, :not_ready} end
             })

    assert :ok =
             TeamBus.register(bus, "repo:infrastructure", %{
               steer: fn _message -> :unexpected end
             })

    assert {:error, {:steer_failed, {:invalid_steer_result, :unexpected}}} =
             TeamBus.send_event(bus, "coordinator", "repo:infrastructure", "check", "status")
  end
end
