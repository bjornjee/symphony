defmodule SymphonyElixir.EngineCommandTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.EngineCommand

  test "captures bounded output and expected process status" do
    assert {:ok, result} = EngineCommand.run(System.tmp_dir!(), "printf hello", timeout_ms: 1_000)
    assert result.exit_status == 0
    assert result.output_tail == "hello"
    assert byte_size(result.output_hash) == 64

    assert {:ok, failed} = EngineCommand.run(System.tmp_dir!(), "printf failure; exit 7", timeout_ms: 1_000)
    assert failed.exit_status == 7
  end

  test "terminates timeout and oversized output" do
    assert {:error, %{reason: :timeout}} = EngineCommand.run(System.tmp_dir!(), "sleep 1", timeout_ms: 20)

    assert {:error, %{reason: :output_limit_exceeded, output_hash: hash}} =
             EngineCommand.run(System.tmp_dir!(), "yes x | head -c 1100000", timeout_ms: 2_000)

    assert byte_size(hash) == 64
  end
end
