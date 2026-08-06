defmodule SymphonyElixir.WorkflowBootstrapTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkflowBootstrap

  test "generates multiple workflow files from shared defaults" do
    in_temp_dir(fn root ->
      manifest_path = Path.join(root, "workflow-manifest.yml")

      File.write!(manifest_path, """
      defaults:
        tracker:
          kind: linear
          api_key: $LINEAR_API_KEY
          required_labels: [codex-ready]
          active_states: [Todo, In Progress, Rework, Merging]
          terminal_states: [Done, Closed, Canceled, Cancelled, Duplicate]
        agent:
          max_concurrent_agents: 1
          max_turns: 12
        codex:
          command: codex app-server
        workspace:
          root: ~/Code/bjornjee/worktrees
      prompt: |
        You are working on Linear issue `{{ issue.identifier }}`.
      workflows:
        - name: alpha
          output_path: workflows/alpha/workflow.md
          tracker:
            project_slug: alpha-project
          repository:
            url: git@github.com:example/alpha.git
        - name: symphony
          output_path: workflows/symphony/workflow.md
          tracker:
            project_slug: symphony-project
          repository:
            url: git@github.com:bjornjee/symphony.git
      """)

      assert {:ok, workflows} = WorkflowBootstrap.bootstrap(manifest_path)
      assert Enum.map(workflows, & &1.name) == ["alpha", "symphony"]

      alpha_workflow_path = Path.join(root, "workflows/alpha/workflow.md")
      symphony_workflow_path = Path.join(root, "workflows/symphony/workflow.md")

      assert File.read!(alpha_workflow_path) =~ "project_slug: \"alpha-project\""
      assert File.read!(alpha_workflow_path) =~ "root: \"~/Code/bjornjee/worktrees/alpha\""
      assert File.read!(alpha_workflow_path) =~ "git clone 'git@github.com:example/alpha.git' ."
      assert File.read!(symphony_workflow_path) =~ "project_slug: \"symphony-project\""
      assert File.read!(symphony_workflow_path) =~ "root: \"~/Code/bjornjee/worktrees/symphony\""
      assert File.read!(symphony_workflow_path) =~ "git clone 'git@github.com:bjornjee/symphony.git' ."

      assert {:ok, %{config: config, prompt: prompt}} = Workflow.load(alpha_workflow_path)
      assert get_in(config, ["tracker", "required_labels"]) == ["codex-ready"]
      assert get_in(config, ["agent", "max_turns"]) == 12

      assert get_in(config, ["team", "repositories", "alpha"]) == %{
               "hooks" => %{"after_create" => "git clone 'git@github.com:example/alpha.git' ."},
               "repository_id" => "example/alpha",
               "workspace" => %{"root" => "~/Code/bjornjee/worktrees/alpha"}
             }

      assert get_in(config, ["team", "repositories", "symphony"]) == %{
               "hooks" => %{"after_create" => "git clone 'git@github.com:bjornjee/symphony.git' ."},
               "repository_id" => "bjornjee/symphony",
               "workspace" => %{"root" => "~/Code/bjornjee/worktrees/symphony"}
             }

      refute get_in(config, ["team", "repositories", "alpha", "repository"])
      assert String.trim(prompt) == "You are working on Linear issue `{{ issue.identifier }}`."
    end)
  end

  test "check mode passes for current outputs and fails for stale outputs" do
    in_temp_dir(fn root ->
      manifest_path = Path.join(root, "workflow-manifest.yml")
      output_path = Path.join(root, "generated/workflow.md")

      File.write!(manifest_path, """
      defaults:
        tracker:
          kind: linear
      prompt: |
        First prompt.
      workflows:
        - name: sample
          output_path: generated/workflow.md
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

  test "rejects malformed manifests and duplicate trusted repository names" do
    in_temp_dir(fn root ->
      missing = Path.join(root, "missing.yml")
      assert {:error, {:bootstrap_manifest_not_found, ^missing, :enoent}} = WorkflowBootstrap.bootstrap(missing)

      manifest_path = Path.join(root, "workflow-manifest.yml")
      File.write!(manifest_path, "[]")
      assert {:error, :bootstrap_manifest_not_a_map} = WorkflowBootstrap.bootstrap(manifest_path)

      File.write!(manifest_path, "workflows: [")
      assert {:error, {:bootstrap_manifest_parse_error, _reason}} = WorkflowBootstrap.bootstrap(manifest_path)

      File.write!(manifest_path, """
      prompt: Coordinate safely.
      workflows:
        - name: duplicate
          output_path: one/workflow.md
          repository:
            url: git@github.com:example/one.git
        - name: duplicate
          output_path: two/workflow.md
          repository:
            url: git@github.com:example/two.git
      """)

      assert {:error, {:bootstrap_duplicate_workflow_name, "duplicate"}} =
               WorkflowBootstrap.bootstrap(manifest_path)

      File.write!(manifest_path, """
      prompt: Coordinate safely.
      workflows:
        - name: unsupported
          output_path: unsupported/workflow.md
          repository:
            url: https://example.com/repository.git
      """)

      assert {:error, {:bootstrap_unsupported_repository_origin, "unsupported"}} =
               WorkflowBootstrap.bootstrap(manifest_path)
    end)
  end

  test "rejects missing and malformed workflow definitions" do
    in_temp_dir(fn root ->
      manifest_path = Path.join(root, "workflow-manifest.yml")

      File.write!(manifest_path, "prompt: Prompt\nworkflows: missing\n")
      assert {:error, :bootstrap_workflows_missing} = WorkflowBootstrap.bootstrap(manifest_path)

      File.write!(manifest_path, "prompt: Prompt\nworkflows:\n  - output_path: workflow.md\n")
      assert {:error, :bootstrap_workflow_name_missing} = WorkflowBootstrap.bootstrap(manifest_path)

      File.write!(manifest_path, "prompt: Prompt\nworkflows:\n  - invalid\n")
      assert {:error, :bootstrap_workflow_not_a_map} = WorkflowBootstrap.bootstrap(manifest_path)
    end)
  end

  test "renders nested and scalar YAML values without losing their types" do
    rendered =
      WorkflowBootstrap.render_workflow(
        %{
          "enabled" => true,
          "disabled" => false,
          "missing" => nil,
          "retries" => 3,
          "matrix" => [
            %{"name" => "application", "required" => true},
            %{"name" => "infrastructure", "required" => false}
          ],
          "mixed" => ["alpha", 2, true, false, nil],
          "notes" => "first line\nsecond line"
        },
        "Prompt"
      )

    assert {:ok, config} =
             YamlElixir.read_from_string(
               rendered
               |> String.split("---\n", parts: 3)
               |> Enum.at(1)
             )

    assert config == %{
             "disabled" => false,
             "enabled" => true,
             "matrix" => [
               %{"name" => "application", "required" => true},
               %{"name" => "infrastructure", "required" => false}
             ],
             "missing" => nil,
             "mixed" => ["alpha", 2, true, false, nil],
             "notes" => "first line\nsecond line\n",
             "retries" => 3
           }
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
