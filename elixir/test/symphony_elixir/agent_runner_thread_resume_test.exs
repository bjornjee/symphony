defmodule SymphonyElixir.AgentRunnerThreadResumeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.ThreadIdentity
  alias SymphonyElixir.CompletionEvidence
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
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-durable"}}}'
            ;;
          *'"method":"thread/resume"'*)
            printf '%s\n' '{"id":5,"result":{"thread":{"id":"thread-durable"}}}'
            ;;
          *'"method":"thread/goal/set"'*)
            printf '%s\n' '{"id":4,"result":{"goal":{"status":"active"}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-retry"}}}'
            printf '%s\n' '{"method":"item/completed","params":{"item":{"type":"commandExecution","command":"mise exec -- make all","exitCode":0}}}'
            printf '%s\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
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

      evidence_validator = fn workspace, evidence_issue, evidence_contract, proofs, _opts ->
        [{proof_event_id, %{exit_code: 0}}] = Map.to_list(proofs)

        payload = %{
          "schema_version" => 1,
          "issue_id" => evidence_issue.id,
          "issue_identifier" => evidence_issue.identifier,
          "plan_digest" => evidence_contract.digest,
          "pull_request_url" => pull_request_url,
          "criteria" =>
            Enum.map(evidence_contract.acceptance_criteria, fn criterion ->
              %{
                "criterion_id" => criterion.id,
                "proof" => %{"kind" => "run_audit_command", "event_id" => proof_event_id}
              }
            end)
        }

        File.mkdir_p!(Path.dirname(CompletionEvidence.path(workspace)))
        File.write!(CompletionEvidence.path(workspace), Jason.encode!(payload))

        CompletionEvidence.validate(workspace, evidence_issue, evidence_contract, proofs,
          origin_url: "git@github.com:bjornjee/symphony.git",
          pull_request_verifier: fn url, _workspace, _worker_host -> {:ok, url} end
        )
      end

      test_pid = self()

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
        handoff_publisher: publisher
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
end
