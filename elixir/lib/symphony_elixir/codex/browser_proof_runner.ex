defmodule SymphonyElixir.Codex.BrowserProofRunner do
  @moduledoc false

  @fixture_request_id 11
  @wait_request_id 12
  @navigate_request_id 13
  @snapshot_request_id 14
  @screenshot_request_id 15
  @close_request_id 16
  @terminate_request_id 17
  @network_request_id 18
  @console_request_id 19
  @tabs_request_id 20
  @cleanup_reserve_ms 1_000
  @max_protocol_payload_bytes 8_388_608
  @max_content_bytes 6_291_456
  @max_snapshot_bytes 5_242_880
  @max_screenshot_bytes 3_145_728

  @spec run(port(), String.t(), Path.t(), Path.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def run(port, thread_id, workspace, directory, command, browser, opts) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    output_bytes_cap = Keyword.fetch!(opts, :output_bytes_cap)
    process_id = Keyword.get_lazy(opts, :process_id, &new_process_id/0)
    deadline = now_ms() + timeout_ms
    work_deadline = deadline - min(@cleanup_reserve_ms, max(div(timeout_ms, 10), 1))
    state = %{pending: "", stdout: "", stderr: "", fixture_done: nil}

    send_request(port, @fixture_request_id, "command/exec", %{
      "command" => clean_fixture_command(command),
      "cwd" => directory,
      "timeoutMs" => max(deadline - now_ms(), 1),
      "outputBytesCap" => output_bytes_cap,
      "processId" => process_id,
      "streamStdoutStderr" => true,
      "sandboxPolicy" => %{
        "type" => "workspaceWrite",
        "writableRoots" => [workspace],
        "networkAccess" => true,
        "excludeSlashTmp" => false,
        "excludeTmpdirEnvVar" => false
      }
    })

    {outcome, state, browser_started?} =
      case await_ready(port, process_id, browser["ready_text"], work_deadline, state) do
        {:ok, ready_state} ->
          safe_browser_checks(port, thread_id, process_id, browser, work_deadline, ready_state)

        {:error, reason, failed_state} ->
          {{:error, reason}, failed_state, false}
      end

    {close_result, state} =
      if browser_started? do
        close_browser(port, thread_id, process_id, work_deadline, state)
      else
        {:ok, state}
      end

    cleanup_result = terminate_fixture(port, process_id, deadline, state)
    result = finalize(outcome, close_result, cleanup_result)

    if session_poisoned?(outcome, close_result, cleanup_result), do: close_port(port)
    result
  end

  defp safe_browser_checks(port, thread_id, process_id, browser, deadline, state) do
    execute_browser_checks(port, thread_id, process_id, browser, deadline, state)
  rescue
    _exception -> {{:error, :browser_protocol_exception}, state, true}
  catch
    _kind, _reason -> {{:error, :browser_protocol_exception}, state, true}
  end

  defp execute_browser_checks(port, thread_id, process_id, browser, deadline, state) do
    with {:ok, _navigation, state} <-
           call_tool(
             port,
             thread_id,
             process_id,
             @navigate_request_id,
             "browser_navigate",
             %{"url" => browser["url"]},
             deadline,
             state
           ),
         {:ok, _wait, state} <-
           call_tool(
             port,
             thread_id,
             process_id,
             @wait_request_id,
             "browser_wait_for",
             %{"text" => hd(browser["snapshot_contains"])},
             deadline,
             state
           ),
         {:ok, snapshot, state} <-
           call_tool(
             port,
             thread_id,
             process_id,
             @snapshot_request_id,
             "browser_snapshot",
             %{},
             deadline,
             state
           ),
         {:ok, screenshot, state} <-
           call_tool(
             port,
             thread_id,
             process_id,
             @screenshot_request_id,
             "browser_take_screenshot",
             %{"type" => "png", "scale" => "css", "fullPage" => true},
             deadline,
             state
           ),
         {:ok, network, state} <-
           call_tool(
             port,
             thread_id,
             process_id,
             @network_request_id,
             "browser_network_requests",
             %{"static" => true},
             deadline,
             state
           ),
         {:ok, console, state} <-
           call_tool(
             port,
             thread_id,
             process_id,
             @console_request_id,
             "browser_console_messages",
             %{"level" => "error", "all" => true},
             deadline,
             state
           ),
         {:ok, tabs, state} <-
           call_tool(
             port,
             thread_id,
             process_id,
             @tabs_request_id,
             "browser_tabs",
             %{"action" => "list"},
             deadline,
             state
           ),
         {:ok, snapshot_text} <- text_content(snapshot, @max_snapshot_bytes),
         {:ok, image} <- png_image(screenshot),
         :ok <- validate_browser_origin(snapshot_text, tabs, browser["url"]),
         :ok <- validate_network_requests(network, browser["url"]),
         :ok <- validate_console(console) do
      outcome =
        if Enum.all?(browser["snapshot_contains"], &String.contains?(snapshot_text, &1)) do
          {:ok, browser_result(snapshot_text, image)}
        else
          {:verification_failed, "snapshot_assertion_failed"}
        end

      {outcome, state, true}
    else
      {:error, reason, state} -> {{:error, reason}, state, true}
      {:error, reason} -> {{:error, reason}, state, true}
    end
  end

  defp close_browser(port, thread_id, process_id, deadline, state) do
    case call_tool(
           port,
           thread_id,
           process_id,
           @close_request_id,
           "browser_close",
           %{},
           deadline,
           state
         ) do
      {:ok, _response, state} -> {:ok, state}
      {:error, reason, state} -> {{:error, reason}, state}
    end
  end

  defp terminate_fixture(port, process_id, deadline, state) do
    case send_request(port, @terminate_request_id, "command/exec/terminate", %{"processId" => process_id}) do
      :ok -> drain_cleanup(port, process_id, deadline, state, false, not is_nil(state.fixture_done))
      {:error, reason} -> {:error, {:browser_cleanup_failed, reason}}
    end
  end

  defp drain_cleanup(_port, _process_id, _deadline, _state, true, true), do: :ok

  defp drain_cleanup(port, process_id, deadline, state, terminate_done?, fixture_done?) do
    case receive_payload(port, deadline, state.pending) do
      {:ok, %{"id" => @terminate_request_id, "result" => _result}, pending} ->
        drain_cleanup(port, process_id, deadline, %{state | pending: pending}, true, fixture_done?)

      {:ok, %{"id" => @fixture_request_id, "result" => _result}, pending} ->
        drain_cleanup(port, process_id, deadline, %{state | pending: pending}, terminate_done?, true)

      {:ok, payload, pending} ->
        next_state = consume_output(payload, process_id, %{state | pending: pending})
        drain_cleanup(port, process_id, deadline, next_state, terminate_done?, fixture_done?)

      {:error, reason, _pending} ->
        {:error, {:browser_cleanup_failed, reason}}
    end
  end

  defp await_ready(port, process_id, ready_text, deadline, state) do
    if String.contains?(state.stdout, ready_text) do
      {:ok, state}
    else
      receive_payload(port, deadline, state.pending)
      |> continue_await_ready(port, process_id, ready_text, deadline, state)
    end
  end

  defp continue_await_ready(
         {:ok, %{"id" => @fixture_request_id, "result" => result}, pending},
         _port,
         _process_id,
         _ready_text,
         _deadline,
         state
       ) do
    {:error, {:fixture_exited_before_ready, result}, %{state | pending: pending, fixture_done: result}}
  end

  defp continue_await_ready(
         {:ok, payload, pending},
         port,
         process_id,
         ready_text,
         deadline,
         state
       ) do
    next_state = consume_output(payload, process_id, %{state | pending: pending})

    if output_cap_reached?(payload, process_id),
      do: {:error, :fixture_output_cap_before_ready, next_state},
      else: await_ready(port, process_id, ready_text, deadline, next_state)
  end

  defp continue_await_ready(
         {:error, reason, pending},
         _port,
         _process_id,
         _ready_text,
         _deadline,
         state
       ) do
    {:error, {:fixture_ready_failed, reason}, %{state | pending: pending}}
  end

  defp call_tool(port, thread_id, process_id, request_id, tool, arguments, deadline, state) do
    request =
      send_request(port, request_id, "mcpServer/tool/call", %{
        "server" => "playwright",
        "threadId" => thread_id,
        "tool" => tool,
        "arguments" => arguments
      })

    case request do
      :ok -> await_tool_response(port, process_id, request_id, tool, deadline, state)
      {:error, reason} -> {:error, {:browser_tool_failed, tool, reason}, state}
    end
  end

  defp await_tool_response(port, process_id, request_id, tool, deadline, state) do
    case receive_payload(port, deadline, state.pending) do
      {:ok, %{"id" => ^request_id, "result" => %{"isError" => false, "content" => content}}, pending} ->
        accept_tool_content(content, pending, state)

      {:ok, %{"id" => ^request_id, "result" => %{"content" => content} = result}, pending}
      when is_list(content) and not is_map_key(result, "isError") ->
        accept_tool_content(content, pending, state)

      {:ok, %{"id" => ^request_id} = response, pending} ->
        {:error, {:browser_tool_failed, tool, response_code(response)}, %{state | pending: pending}}

      {:ok, %{"id" => @fixture_request_id, "result" => result}, pending} ->
        failed_state = %{state | pending: pending, fixture_done: result}
        {:error, {:fixture_exited_during_browser_check, tool, result}, failed_state}

      {:ok, payload, pending} ->
        next_state = consume_output(payload, process_id, %{state | pending: pending})
        await_tool_response(port, process_id, request_id, tool, deadline, next_state)

      {:error, reason, pending} ->
        {:error, {:browser_tool_failed, tool, reason}, %{state | pending: pending}}
    end
  end

  defp accept_tool_content(content, pending, state) do
    if valid_tool_content?(content),
      do: {:ok, content, %{state | pending: pending}},
      else: {:error, :invalid_browser_content, %{state | pending: pending}}
  end

  defp valid_tool_content?(content) when is_list(content) and length(content) <= 64 do
    Enum.reduce_while(content, 0, fn
      %{"type" => "text", "text" => text}, total when is_binary(text) ->
        bounded_content(total, byte_size(text))

      %{"type" => "image", "mimeType" => "image/png", "data" => data}, total
      when is_binary(data) ->
        bounded_content(total, byte_size(data))

      _item, _total ->
        {:halt, :invalid}
    end) != :invalid
  end

  defp valid_tool_content?(_content), do: false

  defp bounded_content(total, bytes) do
    next_total = total + bytes
    if next_total <= @max_content_bytes, do: {:cont, next_total}, else: {:halt, :invalid}
  end

  defp consume_output(
         %{
           "method" => "command/exec/outputDelta",
           "params" => %{
             "processId" => process_id,
             "stream" => stream,
             "deltaBase64" => encoded
           }
         },
         process_id,
         state
       )
       when stream in ["stdout", "stderr"] and is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, chunk} ->
        key = if stream == "stdout", do: :stdout, else: :stderr
        Map.update!(state, key, &bounded_append(&1, chunk))

      :error ->
        state
    end
  end

  defp consume_output(_payload, _process_id, state), do: state

  defp output_cap_reached?(
         %{
           "method" => "command/exec/outputDelta",
           "params" => %{"processId" => process_id, "capReached" => true}
         },
         process_id
       ),
       do: true

  defp output_cap_reached?(_payload, _process_id), do: false

  defp receive_payload(port, deadline, pending) do
    remaining_ms = deadline - now_ms()

    if remaining_ms <= 0 do
      {:error, :response_timeout, pending}
    else
      receive do
        {^port, {:data, {:eol, chunk}}} ->
          decode_payload(pending, to_string(chunk), port, deadline)

        {^port, {:data, {:noeol, chunk}}} ->
          continue_payload(pending, to_string(chunk), port, deadline)

        {^port, {:exit_status, status}} ->
          {:error, {:port_exit, status}, pending}
      after
        remaining_ms ->
          {:error, :response_timeout, pending}
      end
    end
  end

  defp decode_payload(pending, chunk, port, deadline) do
    if byte_size(pending) + byte_size(chunk) > @max_protocol_payload_bytes do
      {:error, :response_too_large, ""}
    else
      case Jason.decode(pending <> chunk) do
        {:ok, payload} when is_map(payload) -> {:ok, payload, ""}
        _other -> receive_payload(port, deadline, "")
      end
    end
  end

  defp continue_payload(pending, chunk, port, deadline) do
    if byte_size(pending) + byte_size(chunk) > @max_protocol_payload_bytes,
      do: {:error, :response_too_large, ""},
      else: receive_payload(port, deadline, pending <> chunk)
  end

  defp text_content(content, max_bytes) do
    text =
      content
      |> Enum.filter(&(Map.get(&1, "type") == "text"))
      |> Enum.map_join("\n", & &1["text"])

    if text != "" and byte_size(text) <= max_bytes,
      do: {:ok, text},
      else: {:error, :invalid_browser_text}
  end

  defp png_image(content) do
    case Enum.find(content, &(Map.get(&1, "type") == "image")) do
      %{"data" => encoded} ->
        with {:ok, image} <- Base.decode64(encoded),
             true <- byte_size(image) in 1..@max_screenshot_bytes,
             true <- valid_png?(image) do
          {:ok, image}
        else
          _other -> {:error, :invalid_browser_screenshot}
        end

      _other ->
        {:error, :invalid_browser_screenshot}
    end
  end

  defp valid_png?(<<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", width::32, height::32, ihdr_tail::binary-size(5), crc::32, rest::binary>>) do
    ihdr = <<width::32, height::32, ihdr_tail::binary>>

    width > 0 and height > 0 and valid_chunk_crc?("IHDR", ihdr, crc) and
      valid_png_chunks?(rest, false)
  end

  defp valid_png?(_image), do: false

  defp valid_png_chunks?(
         <<length::32, type::binary-size(4), chunk_and_rest::binary>>,
         idat_seen?
       )
       when byte_size(chunk_and_rest) >= length + 4 do
    <<data::binary-size(length), crc::32, rest::binary>> = chunk_and_rest

    if valid_chunk_crc?(type, data, crc) do
      case type do
        "IDAT" -> valid_png_chunks?(rest, true)
        "IEND" -> length == 0 and idat_seen? and rest == ""
        "IHDR" -> false
        _other -> valid_png_chunks?(rest, idat_seen?)
      end
    else
      false
    end
  end

  defp valid_png_chunks?(_chunks, _idat_seen?), do: false

  defp valid_chunk_crc?(type, data, crc), do: :erlang.crc32(type <> data) == crc

  defp validate_browser_origin(snapshot, tabs, url) do
    expected_origin = origin(url)
    snapshot_url = capture_url(snapshot, ~r/Page URL:\s+(https?:\/\/[^\s\])]+)/)

    with {:ok, tab_text} <- text_content(tabs, @max_content_bytes) do
      tab_url = capture_url(tab_text, ~r/\(current\).*\((https?:\/\/[^\s\])]+)\)/)

      if is_binary(snapshot_url) and is_binary(tab_url) and
           origin(snapshot_url) == expected_origin and origin(tab_url) == expected_origin,
         do: :ok,
         else: {:error, :browser_origin_changed}
    end
  end

  defp validate_network_requests(content, url) do
    expected_origin = origin(url)

    with {:ok, text} <- text_content(content, @max_content_bytes) do
      urls = extract_network_urls(text)
      http_urls = Enum.filter(urls, &(URI.parse(&1).scheme in ["http", "https"]))

      cond do
        http_urls == [] -> {:error, :browser_network_observation_missing}
        Enum.any?(urls, &(origin(&1) != expected_origin)) -> {:error, :external_browser_request}
        true -> :ok
      end
    end
  end

  defp validate_console(content) do
    with {:ok, text} <- text_content(content, @max_content_bytes) do
      summaries =
        Regex.scan(
          ~r/^Total messages:\s+(\d+)\s+\(Errors:\s+(\d+),\s+Warnings:\s+(\d+)\)\s*$/m,
          text
        )

      case summaries do
        [[_summary, _total, "0", _warnings]] -> :ok
        _other -> {:error, :browser_console_errors}
      end
    end
  end

  defp extract_network_urls(text) do
    ~r{(?:https?|wss?)://[^\s\])]+}
    |> Regex.scan(text)
    |> Enum.map(fn [url] ->
      url
      |> String.trim_trailing(".")
      |> String.trim_trailing(",")
      |> String.trim_trailing("`")
      |> String.trim_trailing("'")
    end)
  end

  defp capture_url(text, pattern) do
    case Regex.run(pattern, text) do
      [_match, url] -> url
      _other -> nil
    end
  end

  defp origin(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https", "ws", "wss"] and is_binary(host) and is_integer(port) ->
        "#{normalize_scheme(scheme)}://#{host}:#{port}"

      _other ->
        nil
    end
  end

  defp normalize_scheme("ws"), do: "http"
  defp normalize_scheme("wss"), do: "https"
  defp normalize_scheme(scheme), do: scheme

  defp browser_result(snapshot, image) do
    snapshot_hash = digest(snapshot)
    image_hash = digest(image)

    %{
      exit_status: 0,
      stdout: "browser proof completed: navigate, snapshot, screenshot\n",
      stderr: "",
      browser_path: "playwright_headless",
      browser_provenance: "mcpServer/tool/call",
      browser_selection_provenance: "codex_global_mcp",
      browser_evidence_hash: digest(snapshot_hash <> image_hash)
    }
  end

  defp finalize({:error, reason}, _close_result, _cleanup_result), do: failure("browser_check", reason)
  defp finalize(_outcome, {:error, reason}, _cleanup_result), do: failure("browser_cleanup", reason)
  defp finalize(_outcome, _close_result, {:error, reason}), do: failure("fixture_cleanup", reason)
  defp finalize({:ok, result}, :ok, :ok), do: {:ok, result}

  defp finalize({:verification_failed, code}, :ok, :ok) do
    {:ok,
     %{
       exit_status: 1,
       stdout: "",
       stderr: "browser proof failed: #{code}\n",
       browser_path: "playwright_headless",
       browser_provenance: "mcpServer/tool/call",
       browser_selection_provenance: "codex_global_mcp",
       browser_failure_stage: "verification",
       browser_failure_code: code
     }}
  end

  defp failure(stage, reason) do
    {:error,
     %{
       reason: "#{stage}:#{failure_code(reason)}",
       browser_path: "playwright_headless",
       browser_provenance: "mcpServer/tool/call",
       browser_selection_provenance: "codex_global_mcp",
       browser_failure_stage: stage,
       browser_failure_code: failure_code(reason)
     }}
  end

  defp failure_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp failure_code({:browser_tool_failed, tool, reason})
       when is_binary(tool) and (is_atom(reason) or is_binary(reason)) do
    normalized_reason = if is_atom(reason), do: Atom.to_string(reason), else: reason
    "#{tool}_#{normalized_reason}"
  end

  defp failure_code({code, _detail}) when is_atom(code), do: Atom.to_string(code)
  defp failure_code({code, _detail, _detail2}) when is_atom(code), do: Atom.to_string(code)
  defp failure_code(_reason), do: "protocol_error"

  defp session_poisoned?(outcome, close_result, cleanup_result) do
    contains_timeout?(outcome) or
      contains_timeout?(close_result) or
      match?({:error, _reason}, close_result) or
      match?({:error, _reason}, cleanup_result)
  end

  defp contains_timeout?(:response_timeout), do: true
  defp contains_timeout?(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.any?(&contains_timeout?/1)
  defp contains_timeout?(_value), do: false

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp response_code(%{"error" => %{"code" => code}}) when is_integer(code), do: "rpc_#{code}"
  defp response_code(%{"result" => %{"isError" => true}}), do: "tool_error"
  defp response_code(_response), do: "invalid_response"

  defp clean_fixture_command(command) do
    [
      "/bin/sh",
      "-c",
      ~S|exec /usr/bin/env -i HOME="$HOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" /bin/sh -c "$1"|,
      "symphony-browser-fixture",
      command
    ]
  end

  defp bounded_append(existing, chunk) do
    combined = existing <> chunk

    if byte_size(combined) <= @max_snapshot_bytes,
      do: combined,
      else: binary_part(combined, byte_size(combined) - @max_snapshot_bytes, @max_snapshot_bytes)
  end

  defp send_request(port, id, method, params) do
    payload = Jason.encode!(%{"id" => id, "method" => method, "params" => params})
    true = Port.command(port, payload <> "\n")
    :ok
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  defp new_process_id do
    "symphony-browser-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
