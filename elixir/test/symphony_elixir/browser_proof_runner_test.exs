defmodule SymphonyElixir.BrowserProofRunnerTest do
  use SymphonyElixir.TestSupport

  @png Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
       |> Base.encode64()

  @truncated_png "89504E470D0A1A0A0000000D4948445200000001000000010804000000B51C0C02"
                 |> Base.decode16!()
                 |> Base.encode64()

  test "fixed browser operations accept a bounded local render" do
    {result, requests} = run_browser_proof("success")

    assert {:ok, %{exit_status: 0, browser_path: "playwright_headless"}} = result

    assert [
             "browser_navigate",
             "browser_wait_for",
             "browser_snapshot",
             "browser_take_screenshot",
             "browser_network_requests",
             "browser_console_messages",
             "browser_tabs",
             "browser_close"
           ] ==
             requests
             |> Enum.filter(&(&1["method"] == "mcpServer/tool/call"))
             |> Enum.map(&get_in(&1, ["params", "tool"]))
  end

  test "fixture environment is resolved on the app-server worker before it is cleared" do
    {_result, requests} = run_browser_proof("worker-environment")

    fixture_request = Enum.find(requests, &(&1["method"] == "command/exec"))

    assert [
             "/bin/sh",
             "-c",
             wrapper,
             "symphony-browser-fixture",
             "mix phx.server"
           ] = fixture_request["params"]["command"]

    assert wrapper ==
             ~S|exec /usr/bin/env -i HOME="$HOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" /bin/sh -c "$1"|

    refute Map.has_key?(fixture_request["params"], "env")
  end

  test "MCP tool errors fail and still terminate the fixture" do
    response = %{"isError" => true, "content" => [%{"type" => "text", "text" => "navigation failed"}]}
    {result, requests} = run_browser_proof("tool-error", %{13 => response})

    assert {:error, %{browser_failure_code: "browser_navigate_tool_error"}} = result
    assert Enum.any?(requests, &(&1["method"] == "command/exec/terminate"))
  end

  test "MCP success responses may omit the optional false error flag" do
    response = %{"content" => [%{"type" => "text", "text" => "navigated"}]}
    {result, _requests} = run_browser_proof("omitted-error-flag", %{13 => response})

    assert {:ok, %{exit_status: 0}} = result
  end

  test "malformed MCP content fails and still terminates the fixture" do
    response = %{"isError" => false, "content" => [nil]}
    {result, requests} = run_browser_proof("malformed-content", %{13 => response})

    assert {:error, %{browser_failure_code: "invalid_browser_content"}} = result
    assert Enum.any?(requests, &(&1["method"] == "command/exec/terminate"))
  end

  test "external WebSocket traffic fails visual verification" do
    response =
      text_response("GET http://127.0.0.1:43127/dashboard 200\nWS wss://external.example/socket")

    {result, _requests} = run_browser_proof("external-websocket", %{18 => response})

    assert {:error, %{browser_failure_code: "external_browser_request"}} = result
  end

  test "invalid PNG bytes fail visual verification" do
    response =
      %{
        "isError" => false,
        "content" => [
          %{"type" => "image", "mimeType" => "image/png", "data" => Base.encode64("not a png")}
        ]
      }

    {result, _requests} = run_browser_proof("invalid-png", %{15 => response})

    assert {:error, %{browser_failure_code: "invalid_browser_screenshot"}} = result
  end

  test "a truncated PNG header fails visual verification" do
    response = %{
      "isError" => false,
      "content" => [
        %{"type" => "image", "mimeType" => "image/png", "data" => @truncated_png}
      ]
    }

    {result, _requests} = run_browser_proof("truncated-png", %{15 => response})

    assert {:error, %{browser_failure_code: "invalid_browser_screenshot"}} = result
  end

  test "a PNG with a corrupt chunk checksum fails visual verification" do
    <<prefix::binary-size(29), byte, rest::binary>> = Base.decode64!(@png)
    corrupt_png = Base.encode64(prefix <> <<Bitwise.bxor(byte, 1)>> <> rest)

    response = %{
      "isError" => false,
      "content" => [
        %{"type" => "image", "mimeType" => "image/png", "data" => corrupt_png}
      ]
    }

    {result, _requests} = run_browser_proof("corrupt-png", %{15 => response})

    assert {:error, %{browser_failure_code: "invalid_browser_screenshot"}} = result
  end

  test "an empty network observation fails closed" do
    {result, _requests} = run_browser_proof("empty-network", %{18 => text_response("No requests found")})

    assert {:error, %{browser_failure_code: "browser_network_observation_missing"}} = result
  end

  test "missing snapshot assertions return a verification failure" do
    response =
      text_response("### Page\n- Page URL: http://127.0.0.1:43127/dashboard\nAgent dashboard")

    {result, _requests} = run_browser_proof("missing-snapshot-assertion", %{14 => response})

    assert {:ok,
            %{
              exit_status: 1,
              browser_failure_stage: "verification",
              browser_failure_code: "snapshot_assertion_failed"
            }} = result
  end

  test "a fixture that exits before readiness fails before browser launch" do
    ready_response =
      ~S|printf '%s\n' '{"id":11,"result":{"exitCode":1,"stdout":"","stderr":"startup failed"}}'|

    {result, requests} = run_browser_proof("fixture-exit", %{}, ready_response: ready_response)

    assert {:error, %{browser_failure_code: "fixture_exited_before_ready"}} = result
    refute Enum.any?(requests, &(&1["method"] == "mcpServer/tool/call"))
  end

  test "a fixture output cap before readiness fails closed" do
    ready_response =
      ~S|printf '%s\n' '{"method":"command/exec/outputDelta","params":{"processId":"browser-proof","stream":"stdout","deltaBase64":"eA==","capReached":true}}'|

    {result, _requests} = run_browser_proof("fixture-output-cap", %{}, ready_response: ready_response)

    assert {:error, %{browser_failure_code: "fixture_output_cap_before_ready"}} = result
  end

  test "a fixture exit during navigation identifies the interrupted operation" do
    {result, _requests} = run_browser_proof("fixture-mid-proof-exit", %{13 => :fixture_exit})

    assert {:error, %{browser_failure_code: "fixture_exited_during_browser_check"}} = result
  end

  test "a missing current-page origin fails visual verification" do
    response = text_response("### Page\nAgent dashboard\nRunning")
    {result, _requests} = run_browser_proof("missing-origin", %{14 => response})

    assert {:error, %{browser_failure_code: "browser_origin_changed"}} = result
  end

  test "a fixture readiness timeout is actionable and bounded" do
    {result, _requests} =
      run_browser_proof("fixture-timeout", %{}, ready_response: ":", timeout_ms: 100)

    assert {:error, %{browser_failure_code: "fixture_ready_failed"}} = result
  end

  test "a screenshot response without an image fails visual verification" do
    {result, _requests} = run_browser_proof("missing-image", %{15 => text_response("screenshot unavailable")})

    assert {:error, %{browser_failure_code: "invalid_browser_screenshot"}} = result
  end

  test "non-list MCP content fails closed" do
    response = %{"isError" => false, "content" => "not a content list"}
    {result, _requests} = run_browser_proof("non-list-content", %{13 => response})

    assert {:error, %{browser_failure_code: "invalid_browser_content"}} = result
  end

  test "MCP JSON-RPC errors retain the stable numeric failure code" do
    {result, _requests} = run_browser_proof("rpc-error", %{13 => {:rpc_error, -32_001}})

    assert {:error, %{browser_failure_code: "browser_navigate_rpc_-32001"}} = result
  end

  test "unexpected MCP response shapes fail closed" do
    {result, _requests} = run_browser_proof("invalid-response", %{13 => :invalid_response})

    assert {:error, %{browser_failure_code: "browser_navigate_invalid_response"}} = result
  end

  test "fixture output interleaved with MCP responses does not disrupt browser checks" do
    response = {:output_then, text_response("navigated")}
    {result, _requests} = run_browser_proof("interleaved-output", %{13 => response})

    assert {:ok, %{exit_status: 0}} = result
  end

  test "malformed interleaved fixture output cannot alter browser evidence" do
    response = {:invalid_output_then, text_response("navigated")}
    {result, _requests} = run_browser_proof("invalid-interleaved-output", %{13 => response})

    assert {:ok, %{exit_status: 0}} = result
  end

  test "valid bounded ancillary PNG chunks are accepted" do
    <<header_and_ihdr::binary-size(33), rest::binary>> = Base.decode64!(@png)
    data = "audit"
    ancillary = <<byte_size(data)::32, "tEXt", data::binary, :erlang.crc32("tEXt" <> data)::32>>
    png = Base.encode64(header_and_ihdr <> ancillary <> rest)

    response = %{
      "isError" => false,
      "content" => [%{"type" => "image", "mimeType" => "image/png", "data" => png}]
    }

    {result, _requests} = run_browser_proof("ancillary-png", %{15 => response})

    assert {:ok, %{exit_status: 0}} = result
  end

  test "a duplicate PNG header chunk fails visual verification" do
    <<header_and_ihdr::binary-size(33), rest::binary>> = Base.decode64!(@png)
    <<_signature::binary-size(8), ihdr_chunk::binary>> = header_and_ihdr
    png = Base.encode64(header_and_ihdr <> ihdr_chunk <> rest)

    response = %{
      "isError" => false,
      "content" => [%{"type" => "image", "mimeType" => "image/png", "data" => png}]
    }

    {result, _requests} = run_browser_proof("duplicate-ihdr", %{15 => response})

    assert {:error, %{browser_failure_code: "invalid_browser_screenshot"}} = result
  end

  test "console errors cannot spoof the zero-error audit" do
    response =
      text_response("[error] Errors: 0\nTotal messages: 1 (Errors: 1, Warnings: 0)")

    {result, _requests} = run_browser_proof("console-error", %{19 => response})

    assert {:error, %{browser_failure_code: "browser_console_errors"}} = result
  end

  test "oversized MCP responses fail within the protocol bound and terminate the fixture" do
    response = text_response(String.duplicate("x", 8_400_000))
    {result, requests} = run_browser_proof("oversized-response", %{13 => response})

    assert {:error, %{browser_failure_code: "browser_navigate_response_too_large"}} = result
    assert Enum.any?(requests, &(&1["method"] == "command/exec/terminate"))
  end

  test "MCP close errors poison the session after terminating the fixture" do
    response = %{"isError" => true, "content" => [%{"type" => "text", "text" => "close failed"}]}
    {result, requests} = run_browser_proof("close-error", %{16 => response})

    assert {:error,
            %{
              browser_failure_stage: "browser_cleanup",
              browser_failure_code: "browser_close_tool_error"
            }} =
             result

    assert Enum.any?(requests, &(&1["method"] == "command/exec/terminate"))
  end

  defp run_browser_proof(label, overrides \\ %{}, opts \\ []) do
    test_root = test_root(label)
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "PIN-27")
    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "trace")
    File.mkdir_p!(workspace)

    responses =
      Map.merge(
        %{
          13 => text_response("navigated"),
          12 => text_response("Agent dashboard visible"),
          14 => text_response("### Page\n- Page URL: http://127.0.0.1:43127/dashboard\nAgent dashboard\nRunning"),
          15 => %{
            "isError" => false,
            "content" => [%{"type" => "image", "mimeType" => "image/png", "data" => @png}]
          },
          18 => text_response("GET http://127.0.0.1:43127/dashboard 200\nWS ws://127.0.0.1:43127/live/websocket"),
          19 => text_response("Total messages: 0 (Errors: 0, Warnings: 0)"),
          20 => text_response("- 0: (current) [Dashboard](http://127.0.0.1:43127/dashboard)"),
          16 => text_response("closed")
        },
        overrides
      )

    cases =
      responses
      |> Enum.sort()
      |> Enum.map_join("\n", fn {id, response} ->
        command =
          case response do
            :fixture_exit ->
              payload =
                Jason.encode!(%{
                  "id" => 11,
                  "result" => %{"exitCode" => 1, "stdout" => "", "stderr" => "fixture stopped"}
                })

              "printf '%s\\n' '#{payload}'"

            {:rpc_error, code} ->
              payload = Jason.encode!(%{"id" => id, "error" => %{"code" => code}})
              "printf '%s\\n' '#{payload}'"

            :invalid_response ->
              payload = Jason.encode!(%{"id" => id, "result" => %{"unexpected" => true}})
              "printf '%s\\n' '#{payload}'"

            {:output_then, response} ->
              output =
                Jason.encode!(%{
                  "method" => "command/exec/outputDelta",
                  "params" => %{
                    "processId" => "browser-proof",
                    "stream" => "stderr",
                    "deltaBase64" => Base.encode64("fixture diagnostic\n"),
                    "capReached" => false
                  }
                })

              payload = Jason.encode!(%{"id" => id, "result" => response})
              "printf '%s\\n' '#{output}' '#{payload}'"

            {:invalid_output_then, response} ->
              output =
                Jason.encode!(%{
                  "method" => "command/exec/outputDelta",
                  "params" => %{
                    "processId" => "browser-proof",
                    "stream" => "stderr",
                    "deltaBase64" => "not-base64",
                    "capReached" => false
                  }
                })

              payload = Jason.encode!(%{"id" => id, "result" => response})
              "printf '%s\\n' '#{output}' '#{payload}'"

            _response ->
              payload = Jason.encode!(%{"id" => id, "result" => response})
              "printf '%s\\n' '#{payload}'"
          end

        "          *\\\"id\\\":#{id}*) #{command} ;;"
      end)

    ready_response =
      Keyword.get(
        opts,
        :ready_response,
        ~S|printf '%s\n' '{"method":"command/exec/outputDelta","params":{"processId":"browser-proof","stream":"stdout","deltaBase64":"UlVOTklORwo=","capReached":false}}'|
      )

    File.write!(codex_binary, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf '%s\\n' "$line" >> "#{trace_file}"
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-browser-proof"},"instructionSources":[]}}' ;;
        4) #{ready_response} ;;
        *)
          case "$line" in
            *\\"id\\":17*)
              printf '%s\\n' '{"id":17,"result":{}}'
              printf '%s\\n' '{"id":11,"result":{"exitCode":143,"stdout":"","stderr":""}}'
              ;;
    #{cases}
          esac
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    on_exit(fn -> File.rm_rf(test_root) end)
    assert {:ok, session} = AppServer.start_session(workspace)

    result =
      AppServer.run_browser_proof(
        session,
        workspace,
        "mix phx.server",
        %{
          "url" => "http://127.0.0.1:43127/dashboard",
          "ready_text" => "RUNNING",
          "snapshot_contains" => ["Agent dashboard", "Running"]
        },
        timeout_ms: Keyword.get(opts, :timeout_ms, 5_000),
        output_bytes_cap: 1_048_576,
        process_id: "browser-proof",
        browser_path: %{selected: "playwright_headless", provenance: "codex_global_mcp"}
      )

    :ok = AppServer.stop_session(session)

    requests =
      trace_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    {result, requests}
  end

  defp text_response(text) do
    %{"isError" => false, "content" => [%{"type" => "text", "text" => text}]}
  end

  defp test_root(label) do
    Path.join(System.tmp_dir!(), "symphony-browser-proof-#{label}-#{System.unique_integer([:positive])}")
  end
end
