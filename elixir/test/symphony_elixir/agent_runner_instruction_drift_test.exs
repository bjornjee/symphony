defmodule SymphonyElixir.AgentRunnerInstructionDriftTest do
  use SymphonyElixir.TestSupport

  test "restart blocks changed instruction authority when implementation commits exist" do
    root =
      Path.join(
        System.tmp_dir!(),
        "agent-runner-instruction-drift-#{System.os_time(:nanosecond)}"
      )

    try do
      source = Path.join(root, "source")
      workspace_root = Path.join(root, "workspaces")
      instruction = Path.join(root, "AGENTS.md")
      codex = Path.join(root, "fake-codex")
      trace = Path.join(root, "codex.trace")
      mutation_marker = Path.join(root, "mutated")
      File.mkdir_p!(source)
      File.write!(instruction, "original doctrine\n")
      File.write!(Path.join(source, "README.md"), "base\n")
      git(source, ["init", "-q", "-b", "main"])
      git(source, ["config", "user.email", "test@example.com"])
      git(source, ["config", "user.name", "Test"])
      git(source, ["add", "README.md"])
      git(source, ["commit", "-qm", "chore: base"])

      File.write!(codex, """
      #!/bin/sh
      while IFS= read -r line; do
        printf '%s\n' "$line" >> "#{trace}"
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-drift"},"instructionSources":["#{instruction}"]}}'
            ;;
          *'"method":"thread/resume"'*)
            printf '%s\n' '{"id":5,"result":{"thread":{"id":"thread-drift"},"instructionSources":["#{instruction}"]}}'
            ;;
          *'"method":"thread/goal/set"'*)
            printf '%s\n' '{"id":4,"result":{"goal":{"status":"active"}}}'
            ;;
          *'"method":"turn/start"'*)
            if [ ! -f "#{mutation_marker}" ]; then
              printf '%s\n' changed > README.md
              git config user.email test@example.com
              git config user.name Test
              git add README.md
              git commit -qm 'fix: implement task'
              touch "#{mutation_marker}"
            fi
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-drift"}}}'
            printf '%s\n' '{"method":"turn/plan/updated","params":{"plan":[{"step":"Implement and prove the task","status":"completed"}]}}'
            printf '%s\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone #{source} .",
        codex_command: "#{codex} app-server",
        tracker_kind: "memory",
        tracker_handoff_state: "Human Review"
      )

      issue = %Issue{
        id: "issue-instruction-drift",
        identifier: "PIN-99",
        title: "fix: respect changed doctrine",
        description: valid_description(),
        state: "In Progress",
        url: "https://example.org/PIN-99",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      {:ok, planning_calls} = Agent.start_link(fn -> 0 end)

      evidence_validator = fn _workspace, _issue, evidence_contract, _proofs, opts ->
        plan = Keyword.fetch!(opts, :execution_plan)

        {:ok,
         %{
           artifact_digest: plan["plan_digest"],
           criteria:
             Enum.map(evidence_contract.acceptance_criteria, fn criterion ->
               %{criterion_id: criterion.id, proof_event_id: "trusted-proof"}
             end),
           pull_request_url: "https://github.com/acme/repo/pull/99"
         }}
      end

      opts = [
        issue_state_fetcher: fn [_id] -> {:ok, [issue]} end,
        completion_evidence_validator: evidence_validator,
        handoff_publisher: fn _issue, _contract, _evidence, _opts ->
          {:ok, %{comment_id: "handoff", issue_state: "Human Review"}}
        end,
        planning_lifecycle_runner: fn session, workspace, planned_issue, planned_contract, profile, planning_opts ->
          Agent.update(planning_calls, &(&1 + 1))

          SymphonyElixir.TestSupport.approve_execution_plan(
            session,
            workspace,
            planned_issue,
            planned_contract,
            profile,
            planning_opts
          )
        end,
        task_branch_ensurer: &accept_task_branch/5
      ]

      assert :ok = AgentRunner.run(issue, nil, opts)
      File.write!(instruction, "changed doctrine\n")

      assert_raise RuntimeError, ~r/instruction_drift_human_review/, fn ->
        AgentRunner.run(issue, nil, opts)
      end

      assert Agent.get(planning_calls, & &1) == 1
      assert_receive {:memory_tracker_comment, "issue-instruction-drift", blocker_id, body}
      assert body =~ "## Agent Blocked"
      assert body =~ "different doctrine"
      assert_receive {:memory_tracker_state_update, "issue-instruction-drift", "Human Review"}
      assert is_binary(blocker_id)

      requests = File.read!(trace)
      assert length(Regex.scan(~r/"method":"turn\/start"/, requests)) == 1
    after
      File.rm_rf(root)
    end
  end

  defp git(workspace, args),
    do: System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true)
end
