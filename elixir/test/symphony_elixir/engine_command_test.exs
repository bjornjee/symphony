defmodule SymphonyElixir.EngineCommandTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.EngineCommand

  test "requires an engine-owned sandbox executor" do
    assert {:error, :sandbox_executor_required} =
             EngineCommand.run(System.tmp_dir!(), "printf hello", timeout_ms: 1_000)
  end

  test "captures bounded sandbox output and expected process status" do
    executor = executor({:ok, %{exit_status: 0, stdout: "hello", stderr: ""}})

    assert {:ok, result} =
             EngineCommand.run(System.tmp_dir!(), "printf hello",
               timeout_ms: 1_000,
               executor: executor
             )

    assert result.exit_status == 0
    assert result.output_tail == "hello"
    assert byte_size(result.output_hash) == 64

    failed_executor = executor({:ok, %{exit_status: 7, stdout: "", stderr: "failure"}})

    assert {:ok, failed} =
             EngineCommand.run(System.tmp_dir!(), "printf failure; exit 7",
               timeout_ms: 1_000,
               executor: failed_executor
             )

    assert failed.exit_status == 7
  end

  test "reports a sandbox timeout" do
    assert {:error, %{reason: :timeout}} =
             EngineCommand.run(System.tmp_dir!(), "sleep 1",
               timeout_ms: 20,
               executor: executor({:error, :timeout})
             )
  end

  test "rejects oversized combined sandbox output" do
    oversized = String.duplicate("x", 1_048_577)

    assert {:error, %{reason: :output_limit_exceeded, output_hash: hash}} =
             EngineCommand.run(System.tmp_dir!(), "large-output",
               timeout_ms: 2_000,
               executor: executor({:ok, %{exit_status: 0, stdout: oversized, stderr: ""}})
             )

    assert byte_size(hash) == 64
  end

  defp executor(result), do: fn _directory, _command, _opts -> result end
end
