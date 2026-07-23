defmodule SymphonyElixir.AgentRunnerThreadResumeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.ThreadIdentity
  alias SymphonyElixir.ExecutionManifest
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

          approve_execution_plan_with_phase(
            session,
            workspace,
            planned_issue,
            planned_contract,
            profile,
            opts
          )
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

      assert :ok = AgentRunner.run(issue, nil, run_opts)

      assert File.read!(ExecutionManifest.path(workspace)) == first_manifest
      assert {:ok, "thread-durable"} = ThreadIdentity.read(workspace)
      assert_receive {:published_handoff, ^first_comment_id, ^first_artifact_digest}
      assert Agent.get(planning_calls, & &1) == 1

      requests =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)

      assert Enum.count(requests, &(&1 == "RUN")) == 2
      assert Enum.count(requests, &String.contains?(&1, "\"method\":\"thread/start\"")) == 1
      assert Enum.count(requests, &String.contains?(&1, "\"method\":\"thread/resume\"")) == 1

      goal_statuses =
        requests
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "thread/goal/set"))
        |> Enum.map(&get_in(&1, ["params", "status"]))

      assert goal_statuses == ["active", "complete", "active", "complete"]
    after
      File.rm_rf(test_root)
    end
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
        "affected_paths" => ["README.md"],
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
      |> put_in(["candidate", "ordered_steps"], ordered_steps)

    {:ok, Map.put(semantic, "plan_digest", SymphonyElixir.PlanningArtifact.digest(semantic))}
  end
end
