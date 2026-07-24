defmodule Mix.Tasks.Symphony.Benchmark.Pin28 do
  @moduledoc "Runs the controlled PIN-28 latency and accuracy benchmark."

  use Mix.Task

  alias SymphonyElixir.Pin28Benchmark

  @shortdoc "Runs the controlled PIN-28 latency and accuracy benchmark"

  @switches [
    runs: :integer,
    check: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, remaining, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] or remaining != [],
      do: Mix.raise("invalid benchmark options: #{inspect(invalid ++ remaining)}")

    case Pin28Benchmark.validate_options(opts) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end

    report = Pin28Benchmark.run(opts)
    Mix.shell().info(Jason.encode!(report, pretty: true))

    case Pin28Benchmark.validate_report(report, opts) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
