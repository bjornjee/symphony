defmodule SymphonyElixir.AgentRunnerThreadResumeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.ThreadIdentity

  test "worker retries resume the same durable Codex thread" do
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

      issue_state_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: issue_state_fetcher)
      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: issue_state_fetcher)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(workspace_root, "PIN-15"))

      assert {:ok, "thread-durable"} = ThreadIdentity.read(workspace)

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
