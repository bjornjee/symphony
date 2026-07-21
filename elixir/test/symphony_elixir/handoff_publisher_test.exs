defmodule SymphonyElixir.HandoffPublisherTest do
  use ExUnit.Case, async: true

  import SymphonyElixir.TaskContractFixtures

  alias SymphonyElixir.HandoffPublisher
  alias SymphonyElixir.Linear.TaskContract

  defmodule FakeTracker do
    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids, issue_ids})
      [result | rest] = Process.get({__MODULE__, :state_fetch_results})
      Process.put({__MODULE__, :state_fetch_results}, rest)
      result
    end

    def fetch_comment(issue_id, comment_id) do
      send(self(), {:fetch_comment, issue_id, comment_id})
      [result | rest] = Process.get({__MODULE__, :fetch_results})
      Process.put({__MODULE__, :fetch_results}, rest)
      result
    end

    def create_comment(issue_id, comment_id, body) do
      send(self(), {:create_comment, issue_id, comment_id, body})
      Process.get({__MODULE__, :create_result}, :ok)
    end

    def update_issue_state(issue_id, state_name) do
      send(self(), {:update_issue_state, issue_id, state_name})
      Process.get({__MODULE__, :state_result}, :ok)
    end
  end

  setup do
    task = issue()
    {:ok, contract} = TaskContract.from_issue(task)

    Process.put({FakeTracker, :state_fetch_results}, [
      {:ok, [task]},
      {:ok, [%{task | state: "Human Review"}]}
    ])

    evidence = %{
      pull_request_url: "https://github.com/bjornjee/symphony/pull/42",
      artifact_digest: String.duplicate("a", 64),
      criteria:
        Enum.map(contract.acceptance_criteria, fn criterion ->
          %{criterion_id: criterion.id, proof_event_id: "proof-#{criterion.id}"}
        end)
    }

    %{task: task, contract: contract, evidence: evidence}
  end

  test "renders only validated human-facing handoff fields", context do
    body = HandoffPublisher.render(context.task, context.contract, Map.put(context.evidence, :raw_logs, "SECRET"))

    assert body =~ "## Agent Handoff"
    assert body =~ context.evidence.pull_request_url
    assert body =~ "Verification: #{length(context.contract.acceptance_criteria)} acceptance criteria passed"
    assert body =~ "Human action: Review and approve the pull request."

    Enum.each(context.contract.acceptance_criteria, fn criterion ->
      assert body =~ criterion.text
      assert body =~ "passed with engine-observed command evidence"
    end)

    refute body =~ "proof-"
    refute body =~ "SECRET"
    refute body =~ "raw_logs"
  end

  test "escapes tracker-authored criterion markdown", context do
    [first | rest] = context.contract.acceptance_criteria
    unsafe = %{first | text: "[click](javascript:alert(1)) <!-- marker -->"}
    contract = %{context.contract | acceptance_criteria: [unsafe | rest]}

    body = HandoffPublisher.render(context.task, contract, context.evidence)

    refute body =~ "[click](javascript:alert(1))"
    assert body =~ "\\[click\\]\\(javascript:alert\\(1\\)\\)"
    assert body =~ "&lt;!-- marker --&gt;"
  end

  test "reuses an exact existing handoff before transitioning state", context do
    issue_id = context.task.id
    comment_id = HandoffPublisher.comment_id(context.task, context.contract, context.evidence)
    body = HandoffPublisher.render(context.task, context.contract, context.evidence)
    Process.put({FakeTracker, :fetch_results}, [{:ok, %{id: comment_id, body: body}}])

    assert {:ok, %{comment_id: ^comment_id, issue_state: "Human Review"}} =
             publish(context)

    assert_receive {:fetch_comment, ^issue_id, ^comment_id}
    refute_receive {:create_comment, _, _, _}
    assert_receive {:update_issue_state, ^issue_id, "Human Review"}
  end

  test "ambiguous comment creation converges through readback", context do
    issue_id = context.task.id
    comment_id = HandoffPublisher.comment_id(context.task, context.contract, context.evidence)
    body = HandoffPublisher.render(context.task, context.contract, context.evidence)

    Process.put({FakeTracker, :fetch_results}, [
      {:ok, nil},
      {:ok, %{id: comment_id, body: body}}
    ])

    Process.put({FakeTracker, :create_result}, {:error, :timeout})

    assert {:ok, %{comment_id: ^comment_id, issue_state: "Human Review"}} =
             publish(context)

    assert_receive {:create_comment, ^issue_id, ^comment_id, ^body}
    assert_receive {:update_issue_state, ^issue_id, "Human Review"}
  end

  test "emits bounded deterministic handoff identity and transition results", context do
    comment_id = HandoffPublisher.comment_id(context.task, context.contract, context.evidence)
    body = HandoffPublisher.render(context.task, context.contract, context.evidence)
    Process.put({FakeTracker, :fetch_results}, [{:ok, %{id: comment_id, body: body}}])
    parent = self()

    assert {:ok, %{comment_id: ^comment_id, issue_state: "Human Review"}} =
             publish(context,
               thread_id: "thread-123",
               event_sink: fn event, attrs -> send(parent, {:handoff_event, event, attrs}) end
             )

    assert_receive {:handoff_event, :handoff_publish_started,
                    %{
                      phase: "handoff",
                      thread_id: "thread-123",
                      plan_digest: plan_digest,
                      artifact_digest: artifact_digest,
                      evidence_result: "accepted",
                      comment_id: ^comment_id,
                      marker_key: marker_key,
                      transition_target: "Human Review"
                    }}

    assert plan_digest == context.contract.digest
    assert artifact_digest == context.evidence.artifact_digest
    assert marker_key =~ ~r/^[a-f0-9]{64}$/

    assert_receive {:handoff_event, :handoff_transition_updated, %{transition_result: "updated", result: "completed", ambiguous: false}}

    assert_receive {:handoff_event, :handoff_transition_result, %{transition_result: "updated", result: "completed", retry: false}}

    refute_receive {:handoff_event, _, %{body: _}}
    refute_receive {:handoff_event, _, %{criteria: _}}
  end

  test "reuses an already completed state transition without another mutation", context do
    comment_id = HandoffPublisher.comment_id(context.task, context.contract, context.evidence)
    body = HandoffPublisher.render(context.task, context.contract, context.evidence)
    Process.put({FakeTracker, :fetch_results}, [{:ok, %{id: comment_id, body: body}}])
    Process.put({FakeTracker, :state_fetch_results}, [{:ok, [%{context.task | state: "Human Review"}]}])
    parent = self()

    assert {:ok, %{issue_state: "Human Review"}} =
             publish(context,
               event_sink: fn event, attrs -> send(parent, {:handoff_event, event, attrs}) end
             )

    refute_receive {:update_issue_state, _, _}

    assert_receive {:handoff_event, :handoff_transition_reused, %{transition_result: "reused", result: "completed", retry: false}}
  end

  test "accepts an ambiguous transition response when readback reached the target", context do
    comment_id = HandoffPublisher.comment_id(context.task, context.contract, context.evidence)
    body = HandoffPublisher.render(context.task, context.contract, context.evidence)
    Process.put({FakeTracker, :fetch_results}, [{:ok, %{id: comment_id, body: body}}])
    Process.put({FakeTracker, :state_result}, {:error, :timeout})
    parent = self()

    assert {:ok, %{issue_state: "Human Review"}} =
             publish(context,
               event_sink: fn event, attrs -> send(parent, {:handoff_event, event, attrs}) end
             )

    assert_receive {:handoff_event, :handoff_transition_ambiguous,
                    %{
                      transition_result: "ambiguous",
                      result: "pending",
                      ambiguous: true,
                      retry: true
                    }}

    assert_receive {:handoff_event, :handoff_transition_result, %{transition_result: "reconciled", result: "completed", retry: false}}
  end

  test "fails closed when a successful transition response does not match readback", context do
    comment_id = HandoffPublisher.comment_id(context.task, context.contract, context.evidence)
    body = HandoffPublisher.render(context.task, context.contract, context.evidence)
    Process.put({FakeTracker, :fetch_results}, [{:ok, %{id: comment_id, body: body}}])

    Process.put({FakeTracker, :state_fetch_results}, [
      {:ok, [context.task]},
      {:ok, [context.task]}
    ])

    assert {:error, {:handoff_state_transition_unverified, "Human Review", "Todo"}} =
             publish(context)
  end

  test "fails closed before mutation when transition state cannot be read", context do
    comment_id = HandoffPublisher.comment_id(context.task, context.contract, context.evidence)
    body = HandoffPublisher.render(context.task, context.contract, context.evidence)
    Process.put({FakeTracker, :fetch_results}, [{:ok, %{id: comment_id, body: body}}])
    Process.put({FakeTracker, :state_fetch_results}, [{:error, :linear_down}])

    assert {:error, {:handoff_state_read_failed, :linear_down}} = publish(context)
    refute_receive {:update_issue_state, _, _}
  end

  test "fails closed when tracker state changes after the runner refresh", context do
    comment_id = HandoffPublisher.comment_id(context.task, context.contract, context.evidence)
    body = HandoffPublisher.render(context.task, context.contract, context.evidence)
    Process.put({FakeTracker, :fetch_results}, [{:ok, %{id: comment_id, body: body}}])
    Process.put({FakeTracker, :state_fetch_results}, [{:ok, [%{context.task | state: "Done"}]}])

    assert {:error, {:handoff_state_source_mismatch, "Todo", "Done", "Human Review"}} =
             publish(context)

    refute_receive {:update_issue_state, _, _}
  end

  test "does not transition when comment readback cannot verify creation", context do
    comment_id = HandoffPublisher.comment_id(context.task, context.contract, context.evidence)
    Process.put({FakeTracker, :fetch_results}, [{:ok, nil}, {:ok, nil}])

    assert {:error, {:handoff_comment_unverified, ^comment_id, :ok}} = publish(context)
    refute_receive {:update_issue_state, _, _}
  end

  test "fails closed on a deterministic comment id collision", context do
    comment_id = HandoffPublisher.comment_id(context.task, context.contract, context.evidence)
    Process.put({FakeTracker, :fetch_results}, [{:ok, %{id: comment_id, body: "different"}}])

    assert {:error, {:handoff_comment_collision, ^comment_id}} = publish(context)
    refute_receive {:create_comment, _, _, _}
    refute_receive {:update_issue_state, _, _}
  end

  test "keeps a verified comment when the state transition must be retried", context do
    comment_id = HandoffPublisher.comment_id(context.task, context.contract, context.evidence)
    body = HandoffPublisher.render(context.task, context.contract, context.evidence)
    Process.put({FakeTracker, :fetch_results}, [{:ok, %{id: comment_id, body: body}}])
    Process.put({FakeTracker, :state_result}, {:error, :linear_down})

    Process.put({FakeTracker, :state_fetch_results}, [
      {:ok, [context.task]},
      {:ok, [context.task]}
    ])

    assert {:error, {:handoff_state_transition_failed, "Human Review", :linear_down}} =
             publish(context)

    refute_receive {:create_comment, _, _, _}
  end

  test "fails closed when initial comment readback fails", context do
    Process.put({FakeTracker, :fetch_results}, [{:error, :linear_down}])

    assert {:error, {:handoff_comment_read_failed, :linear_down}} = publish(context)
    refute_receive {:create_comment, _, _, _}
    refute_receive {:update_issue_state, _, _}
  end

  test "fails closed on unexpected comment read payloads", context do
    Process.put({FakeTracker, :fetch_results}, [:unexpected])
    assert {:error, {:handoff_comment_read_failed, :unexpected}} = publish(context)

    Process.put({FakeTracker, :fetch_results}, [{:ok, nil}, :unexpected])

    assert {:error, {:handoff_comment_read_failed, :unexpected, :ok}} =
             publish(context)
  end

  test "fails closed when post-create readback returns another body", context do
    comment_id = HandoffPublisher.comment_id(context.task, context.contract, context.evidence)

    Process.put({FakeTracker, :fetch_results}, [
      {:ok, nil},
      {:ok, %{id: comment_id, body: "different"}}
    ])

    assert {:error, {:handoff_comment_collision, ^comment_id}} = publish(context)
    refute_receive {:update_issue_state, _, _}
  end

  test "preserves post-create read failures and reconciles an unexpected state response", context do
    Process.put({FakeTracker, :fetch_results}, [{:ok, nil}, {:error, :linear_down}])
    Process.put({FakeTracker, :create_result}, {:error, :timeout})

    assert {:error, {:handoff_comment_read_failed, :linear_down, {:error, :timeout}}} =
             publish(context)

    comment_id = HandoffPublisher.comment_id(context.task, context.contract, context.evidence)
    body = HandoffPublisher.render(context.task, context.contract, context.evidence)
    Process.put({FakeTracker, :fetch_results}, [{:ok, %{id: comment_id, body: body}}])
    Process.put({FakeTracker, :state_result}, :unexpected)

    assert {:ok, %{issue_state: "Human Review"}} = publish(context)
  end

  defp publish(context, opts \\ []) do
    HandoffPublisher.publish(
      context.task,
      context.contract,
      context.evidence,
      Keyword.merge([tracker: FakeTracker, handoff_state: "Human Review"], opts)
    )
  end
end
