defmodule SymphonyElixir.AgentRunnerThreadResumeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.ThreadIdentity
  alias SymphonyElixir.{ExecutionManifest, PlanningArtifact, WorkflowProfile}
  alias SymphonyElixir.HandoffPublisher
  alias SymphonyElixir.Linear.TaskContract

  test "Symphony restarts resume one pinned plan and durable Codex thread through verified handoff" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-agent-runner-thread-resume-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      printf '%s\n' 'RUN' >> "#{trace_file}"
      while IFS= read -r line; do
        printf 'JSON:%s\n' "$line" >> "#{trace_file}"
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-durable"},"instructionSources":[]}}'
            ;;
          *'"method":"thread/resume"'*)
            printf '%s\n' '{"id":5,"result":{"thread":{"id":"thread-durable"},"instructionSources":[]}}'
            ;;
          *'"method":"thread/goal/set"'*)
            printf '%s\n' '{"id":4,"result":{"goal":{"status":"active"}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-retry"}}}'
            printf '%s\n' '{"method":"turn/plan/updated","params":{"plan":[{"step":"Implement and prove the task","status":"completed"}]}}'
            printf '%s\n' '{"method":"item/completed","params":{"item":{"type":"commandExecution","command":"mise exec -- make all","exitCode":0}}}'
            printf '%s\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone #{template_repo} .",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-thread-resume",
        identifier: "PIN-15",
        title: "Resume durable Codex thread",
        description: valid_description(),
        state: "In Progress",
        url: "https://example.org/issues/PIN-15",
        labels: []
      }

      issue_state_fetcher = fn [_issue_id] -> {:ok, [issue]} end
      assert {:ok, contract} = TaskContract.from_issue(issue)
      pull_request_url = "https://github.com/bjornjee/symphony/pull/15"

      evidence_validator = fn _workspace, _issue, evidence_contract, _proofs, opts ->
        execution_plan = Keyword.fetch!(opts, :execution_plan)

        {:ok,
         %{
           artifact_digest: execution_plan["plan_digest"],
           criteria:
             Enum.map(evidence_contract.acceptance_criteria, fn criterion ->
               %{criterion_id: criterion.id, proof_event_id: "trusted-proof-receipt"}
             end),
           pull_request_url: pull_request_url,
           repository_head_sha: String.duplicate("a", 40),
           execution_plan_digest: execution_plan["plan_digest"],
           workflow: execution_plan["workflow"],
           profile_digest: execution_plan["profile_digest"]
         }}
      end

      test_pid = self()
      {:ok, planning_calls} = Agent.start_link(fn -> 0 end)
      {:ok, approved_plan} = Agent.start_link(fn -> nil end)

      publisher = fn published_issue, published_contract, evidence, opts ->
        comment_id = HandoffPublisher.comment_id(published_issue, published_contract, evidence)
        send(test_pid, {:published_handoff, comment_id, evidence.artifact_digest})

        {:ok,
         %{
           comment_id: comment_id,
           issue_state: Keyword.fetch!(opts, :handoff_state)
         }}
      end

      run_opts = [
        issue_state_fetcher: issue_state_fetcher,
        completion_evidence_validator: evidence_validator,
        handoff_publisher: publisher,
        planning_lifecycle_runner: fn session, workspace, planned_issue, planned_contract, profile, opts ->
          Agent.update(planning_calls, &(&1 + 1))

          result =
            approve_execution_plan_with_phase(
              session,
              workspace,
              planned_issue,
              planned_contract,
              profile,
              opts
            )

          case result do
            {:ok, plan} -> Agent.update(approved_plan, fn _ -> plan end)
            _other -> :ok
          end

          result
        end,
        task_branch_ensurer: &accept_task_branch/5,
        capability_diagnostics_resolver: &test_capability_diagnostics/1
      ]

      assert :ok = AgentRunner.run(issue, nil, run_opts)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(workspace_root, "PIN-15"))

      first_manifest = File.read!(ExecutionManifest.path(workspace))
      assert Jason.decode!(first_manifest)["plan_digest"] == contract.digest
      assert {:ok, "thread-durable"} = ThreadIdentity.read(workspace)
      assert_receive {:published_handoff, first_comment_id, first_artifact_digest}

      File.mkdir_p!(Path.join(workspace, "docs"))
      File.write!(Path.join(workspace, "docs/progress.md"), "# uncommitted task progress\n")
      assert :ok = AgentRunner.run(issue, nil, run_opts)

      assert File.read!(ExecutionManifest.path(workspace)) == first_manifest
      assert {:ok, "thread-durable"} = ThreadIdentity.read(workspace)
      assert_receive {:published_handoff, ^first_comment_id, ^first_artifact_digest}

      audit_events =
        workspace
        |> Path.join(".symphony/run-audit.jsonl")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert Enum.any?(audit_events, fn event ->
               event["event"] == "context_cache_result" and
                 event["cache"] == "execution_context" and
                 event["cache_status"] == "hit"
             end)

      assert Enum.any?(audit_events, fn event ->
               event["event"] == "phase_timing" and
                 event["phase"] == "planning" and
                 event["attribution"] == "tool"
             end)

      System.cmd("git", ["-C", workspace, "add", "docs/progress.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "test: checkpoint task progress"])

      assert :ok = AgentRunner.run(issue, nil, run_opts)
      assert_receive {:published_handoff, ^first_comment_id, ^first_artifact_digest}

      System.cmd("git", ["-C", workspace, "commit", "--allow-empty", "-m", "test: empty checkpoint"])
      assert :ok = AgentRunner.run(issue, nil, run_opts)
      assert_receive {:published_handoff, ^first_comment_id, ^first_artifact_digest}

      File.rm!(Path.join(workspace, "docs/progress.md"))
      System.cmd("git", ["-C", workspace, "add", "docs/progress.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "test: revert task progress"])
      assert :ok = AgentRunner.run(issue, nil, run_opts)
      assert_receive {:published_handoff, ^first_comment_id, ^first_artifact_digest}

      current_plan = Agent.get(approved_plan, & &1)

      historical_plan =
        current_plan
        |> Map.put("authority_digest", String.duplicate("f", 64))
        |> Map.put("contract_digest", String.duplicate("e", 64))
        |> Map.put("primary_thread_id", "historical-thread")
        |> Map.delete("plan_digest")

      historical_plan = Map.put(historical_plan, "plan_digest", PlanningArtifact.digest(historical_plan))
      refute historical_plan["authority_digest"] == current_plan["authority_digest"]

      assert :ok =
               AgentRunner.persist_execution_authority_for_benchmark(
                 historical_plan,
                 %{digest: historical_plan["instruction_digest"], paths: []},
                 %{thread_id: "historical-thread"},
                 issue
               )

      File.write!(Path.join(workspace, "docs/resumed-progress.md"), "# resumed task progress\n")
      assert :ok = AgentRunner.run(issue, nil, run_opts)
      assert_receive {:published_handoff, ^first_comment_id, ^first_artifact_digest}
      assert Agent.get(planning_calls, & &1) == 1

      requests =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)

      assert Enum.count(requests, &(&1 == "RUN")) == 6
      assert Enum.count(requests, &String.contains?(&1, "\"method\":\"thread/start\"")) == 1
      assert Enum.count(requests, &String.contains?(&1, "\"method\":\"thread/resume\"")) == 5

      goal_statuses =
        requests
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "thread/goal/set"))
        |> Enum.map(&get_in(&1, ["params", "status"]))

      assert goal_statuses == [
               "active",
               "complete",
               "active",
               "complete",
               "active",
               "complete",
               "active",
               "complete",
               "active",
               "complete",
               "active",
               "complete"
             ]
    after
      File.rm_rf(test_root)
    end
  end

  test "remote repository failures remain retryable instead of becoming instruction drift" do
    failure =
      {:error, {:git_failed, "worker-01:2200", ["branch", "--show-current"], {:ssh_failed, "worker-01:2200", 75, "temporary transport failure"}}}

    assert ^failure =
             AgentRunner.classify_registered_plan_progress_for_test(
               failure,
               String.duplicate("a", 64)
             )
  end

  test "a clean pinned base replans across mixed historical plan receipts" do
    issue = %Issue{
      id: "issue-contract-replan",
      identifier: "PIN-16",
      title: "Update one guide",
      description: valid_description(),
      state: "In Progress",
      url: "https://example.org/issues/PIN-16",
      labels: []
    }

    assert {:ok, old_contract} = TaskContract.from_issue(issue)

    changed_issue = %{
      issue
      | description: String.replace(issue.description, "Deliver one concrete outcome.", "Deliver the corrected outcome.")
    }

    assert {:ok, changed_contract} = TaskContract.from_issue(changed_issue)
    assert {:ok, profile} = WorkflowProfile.select(changed_contract)

    repository = %{
      origin: "git@github.com:acme/repo.git",
      base_sha: String.duplicate("a", 40),
      digest: String.duplicate("b", 64),
      clean: true
    }

    authority = %{digest: String.duplicate("c", 64), paths: []}
    old_session = %{thread_id: "old-thread"}

    old_plan = %{
      "contract_digest" => old_contract.digest,
      "profile_digest" => profile.digest,
      "primary_thread_id" => old_session.thread_id,
      "instruction_digest" => authority.digest,
      "repository" => %{
        "origin" => repository.origin,
        "base_sha" => repository.base_sha,
        "preactivation_digest" => repository.digest
      }
    }

    old_plan = Map.put(old_plan, "plan_digest", PlanningArtifact.digest(old_plan))
    assert :ok = AgentRunner.persist_execution_authority_for_benchmark(old_plan, authority, old_session, issue)

    same_contract_plan = %{
      old_plan
      | "contract_digest" => changed_contract.digest,
        "primary_thread_id" => "another-old-thread"
    }

    same_contract_plan =
      Map.put(
        same_contract_plan,
        "plan_digest",
        same_contract_plan |> Map.delete("plan_digest") |> PlanningArtifact.digest()
      )

    assert :ok =
             AgentRunner.persist_execution_authority_for_benchmark(
               same_contract_plan,
               authority,
               %{thread_id: "another-old-thread"},
               issue
             )

    lookup = fn repository ->
      AgentRunner.registered_execution_plan_for_benchmark(
        repository,
        System.tmp_dir!(),
        changed_issue,
        changed_contract,
        profile,
        %{thread_id: "new-thread"},
        authority
      )
    end

    assert {:ok, :missing} = lookup.(repository)

    assert {:error, :registered_execution_plan_contract_drift} =
             lookup.(%{
               repository
               | base_sha: String.duplicate("d", 40),
                 digest: String.duplicate("e", 64)
             })

    assert {:error, :registered_execution_plan_contract_drift} = lookup.(%{repository | clean: false})
  end

  defp approve_execution_plan_with_phase(session, workspace, issue, contract, profile, opts) do
    {:ok, execution_plan} =
      SymphonyElixir.TestSupport.approve_execution_plan(
        session,
        workspace,
        issue,
        contract,
        profile,
        opts
      )

    ordered_steps = [
      %{
        "id" => "implement",
        "step" => "Implement and prove the task",
        "status" => "in_progress",
        "affected_paths" => ["docs/"],
        "depends_on" => [],
        "verification_profile" => "Targeted",
        "proof_ids" => ["final"],
        "criterion_ids" => [],
        "invariants" => ["the approved task remains bounded"],
        "stop_conditions" => ["stop if the task contract changes"],
        "evidence_requirements" => ["final proof event"]
      }
    ]

    semantic =
      execution_plan
      |> Map.delete("plan_digest")
      |> put_in(["candidate", "affected_paths"], ["docs/"])
      |> put_in(["candidate", "ordered_steps"], ordered_steps)

    {:ok, Map.put(semantic, "plan_digest", SymphonyElixir.PlanningArtifact.digest(semantic))}
  end
end
