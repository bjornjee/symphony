defmodule SymphonyElixir.WorkflowBootstrapTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkflowBootstrap

  test "generates multiple workflow files from shared defaults" do
    in_temp_dir(fn root ->
      manifest_path = Path.join(root, "WORKFLOWS.yml")

      File.write!(manifest_path, """
      defaults:
        tracker:
          kind: linear
          api_key: $LINEAR_API_KEY
          required_labels: [codex-ready]
          active_states: [Todo, In Progress, Rework, Merging]
          terminal_states: [Done, Closed, Canceled, Cancelled, Duplicate]
        agent:
          max_concurrent_agents: 2
          max_turns: 12
        codex:
          command: codex app-server
        workspace:
          root: ~/Code/bjornjee/worktrees
      prompt: |
        You are working on Linear issue `{{ issue.identifier }}`.
      workflows:
        - name: agent-dashboard
          output_path: workflows/agent-dashboard/WORKFLOW.md
          tracker:
            project_slug: agent-project
          repository:
            url: git@github.com:bjornjee/agent-dashboard.git
        - name: symphony
          output_path: workflows/symphony/WORKFLOW.md
          tracker:
            project_slug: symphony-project
          repository:
            url: git@github.com:bjornjee/symphony.git
      """)

      assert {:ok, workflows} = WorkflowBootstrap.bootstrap(manifest_path)
      assert Enum.map(workflows, & &1.name) == ["agent-dashboard", "symphony"]

      agent_workflow_path = Path.join(root, "workflows/agent-dashboard/WORKFLOW.md")
      symphony_workflow_path = Path.join(root, "workflows/symphony/WORKFLOW.md")

      assert File.read!(agent_workflow_path) =~ "project_slug: \"agent-project\""
      assert File.read!(agent_workflow_path) =~ "root: \"~/Code/bjornjee/worktrees/agent-dashboard\""
      assert File.read!(agent_workflow_path) =~ "git clone 'git@github.com:bjornjee/agent-dashboard.git' ."
      assert File.read!(symphony_workflow_path) =~ "project_slug: \"symphony-project\""
      assert File.read!(symphony_workflow_path) =~ "root: \"~/Code/bjornjee/worktrees/symphony\""
      assert File.read!(symphony_workflow_path) =~ "git clone 'git@github.com:bjornjee/symphony.git' ."

      assert {:ok, %{config: config, prompt: prompt}} = Workflow.load(agent_workflow_path)
      assert get_in(config, ["tracker", "required_labels"]) == ["codex-ready"]
      assert get_in(config, ["agent", "max_concurrent_agents"]) == 2
      assert get_in(config, ["agent", "max_turns"]) == 12
      assert String.trim(prompt) == "You are working on Linear issue `{{ issue.identifier }}`."
    end)
  end

  test "check mode passes for current outputs and fails for stale outputs" do
    in_temp_dir(fn root ->
      manifest_path = Path.join(root, "WORKFLOWS.yml")
      output_path = Path.join(root, "generated/WORKFLOW.md")

      File.write!(manifest_path, """
      defaults:
        tracker:
          kind: linear
      prompt: |
        First prompt.
      workflows:
        - name: sample
          output_path: generated/WORKFLOW.md
          tracker:
            project_slug: sample-project
      """)

      assert {:ok, _workflows} = WorkflowBootstrap.bootstrap(manifest_path)
      assert {:ok, _workflows} = WorkflowBootstrap.bootstrap(manifest_path, check: true)

      File.write!(output_path, "stale")

      assert {:error, {:bootstrap_outputs_stale, [^output_path]}} =
               WorkflowBootstrap.bootstrap(manifest_path, check: true)
    end)
  end

  defp in_temp_dir(fun) do
    root = Path.join(System.tmp_dir!(), "workflow-bootstrap-test-#{System.unique_integer([:positive, :monotonic])}")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end
end
