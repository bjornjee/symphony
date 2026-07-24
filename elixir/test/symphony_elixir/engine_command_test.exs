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

  test "preserves safe browser execution provenance from the sandbox executor" do
    executor =
      executor(
        {:ok,
         %{
           exit_status: 0,
           stdout: "passed",
           stderr: "",
           browser_path: "playwright_headless",
           browser_provenance: "mcpServer/tool/call",
           browser_selection_provenance: "codex_global_mcp",
           browser_evidence_hash: String.duplicate("d", 64)
         }}
      )

    assert {:ok, result} =
             EngineCommand.run(System.tmp_dir!(), "npm test",
               timeout_ms: 1_000,
               executor: executor
             )

    assert Map.take(result, [
             :browser_path,
             :browser_provenance,
             :browser_selection_provenance,
             :browser_evidence_hash
           ]) == %{
             browser_path: "playwright_headless",
             browser_provenance: "mcpServer/tool/call",
             browser_selection_provenance: "codex_global_mcp",
             browser_evidence_hash: String.duplicate("d", 64)
           }
  end

  test "reports a sandbox timeout" do
    assert {:error, %{reason: :timeout}} =
             EngineCommand.run(System.tmp_dir!(), "sleep 1",
               timeout_ms: 20,
               executor: executor({:error, :timeout})
             )
  end

  test "preserves selected browser provenance when the browser runner fails" do
    error = %{
      reason: "browser capability unavailable",
      browser_path: "playwright_headless",
      browser_selection_provenance: "codex_global_mcp",
      browser_failure_stage: "capability",
      browser_failure_code: "browser_capability_unavailable"
    }

    assert {:error, result} =
             EngineCommand.run(System.tmp_dir!(), "npm test",
               timeout_ms: 20,
               executor: executor({:error, error})
             )

    assert result.reason == "browser capability unavailable"
    assert result.browser_path == "playwright_headless"
    assert result.browser_selection_provenance == "codex_global_mcp"
    assert result.browser_failure_stage == "capability"
    assert result.browser_failure_code == "browser_capability_unavailable"
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
