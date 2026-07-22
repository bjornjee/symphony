defmodule SymphonyElixir.PlanningLifecycleTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.TaskContract
  alias SymphonyElixir.PlanningLifecycle
  alias SymphonyElixir.TaskContractFixtures
  alias SymphonyElixir.WorkflowProfile

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-planning-lifecycle-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    issue = TaskContractFixtures.issue()
    {:ok, contract} = TaskContract.from_issue(issue)
    {:ok, profile} = WorkflowProfile.select(contract)

    repository = %{
      origin: "git@github.com:acme/repo.git",
      base_sha: String.duplicate("c", 40),
      digest: String.duplicate("d", 64)
    }

    %{workspace: workspace, issue: issue, contract: contract, profile: profile, repository: repository}
  end

  test "orders native plan update, medium review, and approval before returning a sealed plan", ctx do
    parent = self()
    candidate = candidate(ctx)

    run_turn = fn session, _prompt, _issue, opts ->
      send(parent, {:turn, session.role, Keyword.take(opts, [:sandbox_policy, :approval_policy, :effort])})

      case session.role do
        :primary ->
          opts[:on_message].(%{
            event: :notification,
            payload: %{"method" => "turn/plan/updated", "params" => %{"plan" => candidate["ordered_steps"]}}
          })

          assert %{"success" => true} = opts[:tool_executor].("submit_execution_plan", candidate)
          assert %{"success" => false} = opts[:tool_executor].("submit_execution_plan", candidate)

        :reviewer ->
          review = %{
            "candidate_digest" => SymphonyElixir.PlanningArtifact.digest(candidate),
            "verdict" => "approve",
            "blocking_findings" => [],
            "advisory_findings" => [],
            "workflow" => ctx.profile.name,
            "profile_digest" => ctx.profile.digest
          }

          assert %{"success" => true} = opts[:tool_executor].("submit_plan_review", review)
          assert %{"success" => false} = opts[:tool_executor].("submit_plan_review", review)
      end

      {:ok, %{turn_id: "turn-#{session.role}"}}
    end

    opts = [
      repository_capture: fn _workspace, _host -> {:ok, ctx.repository} end,
      issue_fetcher: fn [_id] -> {:ok, [ctx.issue]} end,
      run_turn: run_turn,
      start_reviewer_session: fn _workspace, reviewer_opts ->
        send(parent, {:reviewer_started, reviewer_opts})
        {:ok, %{role: :reviewer, thread_id: "review-thread"}}
      end,
      stop_session: fn _session -> :ok end
    ]

    assert {:ok, plan} =
             PlanningLifecycle.run(
               %{role: :primary, thread_id: "primary-thread"},
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               ctx.profile,
               opts
             )

    assert byte_size(plan["plan_digest"]) == 64

    assert_receive {:turn, :primary, primary_opts}
    assert primary_opts[:sandbox_policy] == %{"type" => "readOnly", "networkAccess" => false}
    refute Keyword.has_key?(primary_opts, :effort)

    assert_receive {:reviewer_started, reviewer_opts}
    assert reviewer_opts[:dynamic_tools] == SymphonyElixir.PlanningArtifact.review_tool_specs()

    assert_receive {:turn, :reviewer, reviewer_turn_opts}
    assert reviewer_turn_opts[:effort] == "medium"
    assert reviewer_turn_opts[:sandbox_policy] == %{"type" => "readOnly", "networkAccess" => false}

    assert {:ok, ^plan} =
             PlanningLifecycle.run(
               %{role: :primary, thread_id: "primary-thread"},
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               ctx.profile,
               run_turn: fn _, _, _, _ -> flunk("approved restart must not rerun a turn") end
             )
  end

  test "simple tasks seal direct execution without a plan or review turn", ctx do
    description =
      TaskContractFixtures.valid_description(%{
        "Goal" => "Correct one documentation example.",
        "Scope" => "In:\n- docs/guide.md\n\nOut:\n- source code",
        "Acceptance Criteria" => "- [ ] Guide example is current.",
        "Verification" => "Run:\n`mix test test/docs_test.exs`",
        "Risk" => "low",
        "Notes For Agent" => "Workflow: chore"
      })

    issue = TaskContractFixtures.issue(%{title: "docs: correct guide example", description: description})
    {:ok, contract} = TaskContract.from_issue(issue)
    {:ok, profile} = WorkflowProfile.select(contract)

    assert {:ok, plan} =
             PlanningLifecycle.run(
               %{role: :primary, thread_id: "primary-thread"},
               ctx.workspace,
               issue,
               contract,
               profile,
               repository_capture: fn _, _ -> {:ok, ctx.repository} end,
               issue_fetcher: fn [_id] -> {:ok, [issue]} end,
               run_turn: fn _, _, _, _ -> flunk("simple task must not start a planning turn") end,
               start_reviewer_session: fn _, _ -> flunk("simple task must not start a reviewer") end
             )

    assert plan["execution_mode"] == "simple"
    assert plan["candidate"] == nil
    assert plan["repository"]["base_sha"] == ctx.repository.base_sha
    assert plan["proof_commands"] == ["mix test test/docs_test.exs"]
  end

  test "rejects a planning turn that emits a file-change event", ctx do
    run_turn = fn _session, _prompt, _issue, opts ->
      assert %{"success" => false} = opts[:tool_executor].("unexpected", %{})
      assert %{"success" => false} = opts[:tool_executor].("submit_execution_plan", "invalid")

      opts[:on_message].(%{event: :notification, payload: %{"method" => "turn/other", "params" => %{}}})

      opts[:on_message].(%{
        event: :notification,
        payload: %{
          "method" => "item/completed",
          "params" => %{"item" => %{"type" => "commandExecution"}}
        }
      })

      opts[:on_message].(%{
        event: :notification,
        payload: %{"method" => "item/fileChange/outputDelta", "params" => %{}}
      })

      {:ok, %{turn_id: "turn-primary"}}
    end

    assert {:error, :preactivation_file_change} =
             PlanningLifecycle.run(
               %{role: :primary, thread_id: "primary-thread"},
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               ctx.profile,
               repository_capture: fn _workspace, _host -> {:ok, ctx.repository} end,
               run_turn: run_turn
             )
  end

  test "requires both a native plan update and one structured submission", ctx do
    assert {:error, :native_plan_update_missing} =
             PlanningLifecycle.run(
               %{role: :primary, thread_id: "primary-thread"},
               Path.join(ctx.workspace, "no-plan"),
               ctx.issue,
               ctx.contract,
               ctx.profile,
               repository_capture: fn _, _ -> {:ok, ctx.repository} end,
               run_turn: fn _, _, _, _ -> {:ok, %{turn_id: "empty"}} end
             )

    candidate = candidate(ctx)

    assert {:error, :execution_plan_submission_missing} =
             PlanningLifecycle.run(
               %{role: :primary, thread_id: "primary-thread"},
               Path.join(ctx.workspace, "no-submission"),
               ctx.issue,
               ctx.contract,
               ctx.profile,
               repository_capture: fn _, _ -> {:ok, ctx.repository} end,
               run_turn: fn _, _, _, opts ->
                 opts[:on_message].(%{
                   event: :notification,
                   payload: %{
                     "method" => "turn/plan/updated",
                     "params" => %{"plan" => candidate["ordered_steps"]}
                   }
                 })

                 {:ok, %{turn_id: "plan-only"}}
               end
             )
  end

  test "permits exactly two revisions before approving the third candidate", ctx do
    {:ok, counter} = Agent.start_link(fn -> %{primary: 0, reviewer: 0} end)

    run_turn = fn session, _prompt, _issue, opts ->
      revision =
        Agent.get_and_update(counter, fn counts ->
          current = Map.fetch!(counts, session.role) + 1
          {current, Map.put(counts, session.role, current)}
        end)

      candidate = candidate(ctx, revision)

      if session.role == :primary do
        opts[:on_message].(%{
          event: :notification,
          payload: %{"method" => "turn/plan/updated", "params" => %{"plan" => candidate["ordered_steps"]}}
        })

        opts[:tool_executor].("submit_execution_plan", candidate)
      else
        verdict = if revision < 3, do: "revise", else: "approve"

        opts[:tool_executor].("submit_plan_review", %{
          "candidate_digest" => SymphonyElixir.PlanningArtifact.digest(candidate),
          "verdict" => verdict,
          "blocking_findings" => if(verdict == "revise", do: ["Revise candidate #{revision}."], else: []),
          "advisory_findings" => [],
          "workflow" => ctx.profile.name,
          "profile_digest" => ctx.profile.digest
        })
      end

      {:ok, %{turn_id: "turn-#{session.role}-#{revision}"}}
    end

    assert {:ok, %{"revision" => 3}} =
             PlanningLifecycle.run(
               %{role: :primary, thread_id: "primary-thread"},
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               ctx.profile,
               repository_capture: fn _, _ -> {:ok, ctx.repository} end,
               issue_fetcher: fn _ -> {:ok, [ctx.issue]} end,
               run_turn: run_turn,
               start_reviewer_session: fn _, _ ->
                 {:ok, %{role: :reviewer, thread_id: "review-thread"}}
               end,
               stop_session: fn _ -> :ok end
             )

    assert Agent.get(counter, & &1) == %{primary: 3, reviewer: 3}
    Agent.stop(counter)
  end

  test "the third revision verdict invokes one exhaustion handoff", ctx do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_handoff_state: "Human Review"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [ctx.issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    {:ok, counter} = Agent.start_link(fn -> %{primary: 0, reviewer: 0} end)

    run_turn = fn session, _prompt, _issue, opts ->
      revision =
        Agent.get_and_update(counter, fn counts ->
          current = Map.fetch!(counts, session.role) + 1
          {current, Map.put(counts, session.role, current)}
        end)

      candidate = candidate(ctx, revision)

      if session.role == :primary do
        opts[:on_message].(%{
          event: :notification,
          payload: %{"method" => "turn/plan/updated", "params" => %{"plan" => candidate["ordered_steps"]}}
        })

        opts[:tool_executor].("submit_execution_plan", candidate)
      else
        opts[:tool_executor].("submit_plan_review", %{
          "candidate_digest" => SymphonyElixir.PlanningArtifact.digest(candidate),
          "verdict" => "revise",
          "blocking_findings" => ["Still incomplete."],
          "advisory_findings" => [],
          "workflow" => ctx.profile.name,
          "profile_digest" => ctx.profile.digest
        })
      end

      {:ok, %{turn_id: "turn-#{session.role}-#{revision}"}}
    end

    assert {:error, {:plan_review_exhausted, comment_id}} =
             PlanningLifecycle.run(
               %{role: :primary, thread_id: "primary-thread"},
               ctx.workspace,
               ctx.issue,
               ctx.contract,
               ctx.profile,
               repository_capture: fn _, _ -> {:ok, ctx.repository} end,
               run_turn: run_turn,
               start_reviewer_session: fn _, _ ->
                 {:ok, %{role: :reviewer, thread_id: "review-thread"}}
               end,
               stop_session: fn _ -> :ok end
             )

    assert_receive {:memory_tracker_comment, issue_id, ^comment_id, body}
    assert issue_id == ctx.issue.id
    assert body =~ "## Agent Blocked"
    assert body =~ "Still incomplete."
    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}
    refute_receive {:memory_tracker_comment, ^issue_id, ^comment_id, _body}
    Agent.stop(counter)
  end

  defp candidate(ctx, revision \\ 1) do
    %{
      "issue_id" => ctx.issue.id,
      "issue_identifier" => ctx.issue.identifier,
      "contract_digest" => ctx.contract.digest,
      "workflow" => ctx.profile.name,
      "profile_digest" => ctx.profile.digest,
      "primary_thread_id" => "primary-thread",
      "ordered_steps" => [
        phase(
          "inspect",
          "Inspect the current behavior (revision #{revision})",
          "in_progress",
          []
        ),
        phase("implement", "Implement and verify", "pending", ["inspect"])
      ],
      "affected_paths" => ["lib/example.ex"],
      "scope" => %{"in" => ["requested behavior"], "out" => ["unrelated cleanup"]},
      "execution_context" => "request/response; once per request",
      "scale_shape" => "bounded by one request",
      "verification_profile" => "Targeted",
      "proof_commands" => ["mix test test/example_test.exs"],
      "risks" => [],
      "invariants" => ["existing behavior remains stable"],
      "rollback" => "revert the task commit",
      "evidence_requirements" => [],
      "repository" => %{
        "origin" => ctx.repository.origin,
        "base_sha" => ctx.repository.base_sha,
        "preactivation_digest" => ctx.repository.digest
      }
    }
  end

  defp phase(id, step, status, depends_on) do
    %{
      "id" => id,
      "step" => step,
      "status" => status,
      "affected_paths" => ["lib/example.ex"],
      "depends_on" => depends_on,
      "verification_profile" => "Targeted",
      "proof_commands" => ["mix test test/example_test.exs"],
      "invariants" => ["existing behavior remains stable"],
      "stop_conditions" => ["Stop if the approved scope must expand"],
      "evidence_requirements" => []
    }
  end
end
