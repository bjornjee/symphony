defmodule Mix.Tasks.Symphony.Benchmark.Pin28 do
  @moduledoc "Runs the controlled PIN-28 latency and accuracy benchmark."

  use Mix.Task

  alias SymphonyElixir.Pin28Benchmark

  @shortdoc "Runs the controlled PIN-28 latency and accuracy benchmark"

  @switches [
    runs: :integer,
    observation_delay_ms: :integer,
    fixed_overhead_ms: :integer,
    check: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _remaining, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("invalid benchmark options: #{inspect(invalid)}")

    report = Pin28Benchmark.run(opts)
    Mix.shell().info(Jason.encode!(report, pretty: true))

    if Keyword.get(opts, :check, false) and not report.thresholds_passed do
      Mix.raise("PIN-28 benchmark thresholds failed")
    end
  end
end
