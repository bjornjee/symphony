defmodule Mix.Tasks.Workflow.Bootstrap do
  @moduledoc """
  Generates runnable workflow.md files from a bootstrap manifest.
  """

  use Mix.Task

  alias SymphonyElixir.WorkflowBootstrap

  @shortdoc "Generates workflow.md files from a bootstrap manifest"
  @switches [manifest: :string, check: :boolean]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise(usage())
    end

    manifest_path = opts |> Keyword.get(:manifest, "../workflow-manifest.yml") |> Path.expand(File.cwd!())

    case WorkflowBootstrap.bootstrap(manifest_path, check: Keyword.get(opts, :check, false)) do
      {:ok, workflows} ->
        Enum.each(workflows, fn workflow ->
          Mix.shell().info("generated #{workflow.name}: #{workflow.output_path}")
        end)

      {:error, reason} ->
        Mix.raise("workflow.bootstrap failed: #{inspect(reason)}")
    end

    :ok
  end

  defp usage do
    "Usage: mix workflow.bootstrap [--manifest ../workflow-manifest.yml] [--check]"
  end
end
