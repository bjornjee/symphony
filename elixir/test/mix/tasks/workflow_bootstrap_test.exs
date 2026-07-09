defmodule Mix.Tasks.WorkflowBootstrapTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Workflow.Bootstrap

  setup do
    Mix.Task.reenable("workflow.bootstrap")
    :ok
  end

  test "generates workflows through the mix task" do
    in_temp_dir(fn root ->
      manifest_path = Path.join(root, "workflow-manifest.yml")

      File.write!(manifest_path, """
      prompt: |
        Task prompt.
      workflows:
        - name: sample
          output_path: generated/workflow.md
          tracker:
            kind: linear
            project_slug: sample-project
      """)

      output =
        capture_io(fn ->
          assert :ok = Bootstrap.run(["--manifest", manifest_path])
        end)

      assert output =~ "generated sample:"
      assert File.exists?(Path.join(root, "generated/workflow.md"))
    end)
  end

  defp in_temp_dir(fun) do
    root = Path.join(System.tmp_dir!(), "workflow-bootstrap-task-test-#{System.unique_integer([:positive, :monotonic])}")

    File.rm_rf!(root)
    File.mkdir_p!(root)

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end
end
