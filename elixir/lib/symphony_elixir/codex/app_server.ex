defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger

  alias SymphonyElixir.{
    Codex.CapabilityDiagnostics,
    Codex.DynamicTool,
    Codex.PlaywrightProofServer,
    Config,
    PathSafety,
    SSH
  }

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @thread_goal_set_id 4
  @thread_resume_id 5
  @command_exec_id 6
  @plugin_list_id 7
  @mcp_status_id 8
  @capability_runtime_probe_id 9
  @playwright_runtime_probe_id 10
  @capability_probe_timeout_ms 30_000
  @required_playwright_tools ~w(
    browser_navigate
    browser_snapshot
    browser_tabs
    browser_take_screenshot
  )
  @goal_statuses ~w(active blocked complete)
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."
  @proof_secret_env ~w(
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    GITHUB_TOKEN GH_TOKEN LINEAR_API_KEY
    OPENAI_API_KEY CODEX_API_KEY ANTHROPIC_API_KEY
  )

  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          instruction_sources: [map()],
          workspace: Path.t(),
          worker_host: String.t() | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host) do
      metadata = port_metadata(port, worker_host)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host),
           {:ok, thread_id, instruction_sources} <-
             do_start_session(
               port,
               expanded_workspace,
               session_policies,
               Keyword.get(opts, :thread_id),
               Keyword.get(opts, :dynamic_tools, DynamicTool.tool_specs())
             ) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.approval_policy == "never",
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           instruction_sources: instruction_sources,
           workspace: expanded_workspace,
           worker_host: worker_host
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    approval_policy = Keyword.get(opts, :approval_policy, approval_policy)
    turn_sandbox_policy = Keyword.get(opts, :sandbox_policy, turn_sandbox_policy)
    auto_approve_requests = Keyword.get(opts, :auto_approve_requests, auto_approve_requests)
    command_approval_authorizer = Keyword.get(opts, :command_approval_authorizer)

    approval_mode =
      if is_function(command_approval_authorizer, 1) do
        {:command_only, command_approval_authorizer}
      else
        auto_approve_requests
      end

    effort = Keyword.get(opts, :effort)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments)
      end)

    case start_turn(
           port,
           thread_id,
           prompt,
           issue,
           workspace,
           approval_policy,
           turn_sandbox_policy,
           effort
         ) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        case await_turn_completion(port, on_message, tool_executor, approval_mode) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec run_command(session(), Path.t(), String.t(), keyword()) ::
          {:ok, %{exit_status: integer(), stdout: String.t(), stderr: String.t()}} | {:error, term()}
  def run_command(%{port: port, workspace: workspace, worker_host: worker_host}, directory, command, opts)
      when is_binary(directory) and is_binary(command) do
    with {:ok, command_directory} <- validate_command_directory(workspace, directory, worker_host) do
      browser_path = Keyword.get(opts, :browser_path)

      if browser_path[:selected] == "playwright_headless" do
        run_playwright_command(
          port,
          workspace,
          command_directory,
          command,
          opts,
          worker_host,
          browser_path
        )
      else
        do_run_command(port, workspace, command_directory, command, opts, nil, nil)
      end
    end
  end

  defp run_playwright_command(port, workspace, directory, command, opts, worker_host, browser_path) do
    playwright_server = Keyword.get(opts, :playwright_server, &PlaywrightProofServer.with_endpoint/4)

    case playwright_server.(
           workspace,
           directory,
           worker_host,
           &do_run_command(port, workspace, directory, command, opts, browser_path, &1)
         ) do
      {:error, %{reason: _reason}} = error ->
        error

      {:error, reason} ->
        {:error,
         browser_selection_metadata(browser_path)
         |> Map.put(:reason, inspect(reason))}

      result ->
        result
    end
  end

  defp do_run_command(port, workspace, command_directory, command, opts, browser_path, browser_server) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    output_bytes_cap = Keyword.fetch!(opts, :output_bytes_cap)

    environment =
      Map.put(Map.new(@proof_secret_env, &{&1, nil}), "PATH", System.get_env("PATH"))
      |> maybe_put_browser_endpoint(browser_server)

    send_message(port, %{
      "method" => "command/exec",
      "id" => @command_exec_id,
      "params" => %{
        "command" => ["sh", "-c", command],
        "cwd" => command_directory,
        "timeoutMs" => timeout_ms,
        "outputBytesCap" => output_bytes_cap,
        "env" => environment,
        "sandboxPolicy" => %{
          "type" => "workspaceWrite",
          "writableRoots" => [workspace],
          "networkAccess" => true,
          "excludeSlashTmp" => false,
          "excludeTmpdirEnvVar" => false
        }
      }
    })

    case await_response(port, @command_exec_id, timeout_ms + 5_000) do
      {:ok, %{"exitCode" => status, "stdout" => stdout, "stderr" => stderr}}
      when is_integer(status) and is_binary(stdout) and is_binary(stderr) ->
        result = %{
          exit_status: status,
          stdout: redact_browser_endpoint(stdout, browser_server),
          stderr: redact_browser_endpoint(stderr, browser_server)
        }

        {:ok, Map.merge(result, browser_metadata(browser_path, browser_server))}

      {:ok, payload} ->
        reason = {:invalid_command_exec_response, redact_browser_endpoint(payload, browser_server)}
        {:error, browser_failure(reason, browser_path, browser_server)}

      {:error, reason} ->
        {:error, browser_failure(reason, browser_path, browser_server)}
    end
  end

  defp maybe_put_browser_endpoint(environment, %{endpoint: endpoint}) when is_binary(endpoint),
    do: Map.put(environment, "PW_TEST_CONNECT_WS_ENDPOINT", endpoint)

  defp maybe_put_browser_endpoint(environment, _browser_server), do: environment

  defp browser_metadata(%{provenance: selection_provenance}, %{
         path: path,
         provenance: provenance,
         version: version
       })
       when is_binary(path) and is_binary(provenance) and is_binary(selection_provenance) and
              is_binary(version) do
    %{
      browser_path: path,
      browser_provenance: provenance,
      browser_selection_provenance: selection_provenance,
      browser_version: version
    }
  end

  defp browser_metadata(_browser_path, _browser_server), do: %{}

  defp browser_selection_metadata(%{selected: path, provenance: provenance})
       when is_binary(path) and is_binary(provenance) do
    %{browser_path: path, browser_selection_provenance: provenance}
  end

  defp browser_selection_metadata(_browser_path), do: %{}

  defp browser_failure(reason, browser_path, browser_server) do
    browser_path
    |> browser_metadata(browser_server)
    |> Map.put(:reason, inspect(reason))
  end

  defp redact_browser_endpoint(value, %{endpoint: endpoint}) when is_binary(value) and is_binary(endpoint),
    do: String.replace(value, endpoint, "[REDACTED_PLAYWRIGHT_ENDPOINT]")

  defp redact_browser_endpoint(value, %{endpoint: endpoint}) when is_map(value) and is_binary(endpoint),
    do: Map.new(value, fn {key, item} -> {key, redact_browser_endpoint(item, %{endpoint: endpoint})} end)

  defp redact_browser_endpoint(value, %{endpoint: endpoint}) when is_list(value) and is_binary(endpoint),
    do: Enum.map(value, &redact_browser_endpoint(&1, %{endpoint: endpoint}))

  defp redact_browser_endpoint(value, _browser_server), do: value

  @spec set_goal(session(), String.t(), keyword()) :: :ok | {:error, term()}
  def set_goal(%{port: port, thread_id: thread_id}, objective, opts \\ [])
      when is_binary(thread_id) and is_binary(objective) do
    objective = String.trim(objective)

    if objective == "" do
      {:error, :empty_goal_objective}
    else
      token_budget = Keyword.get(opts, :token_budget)
      status = Keyword.get(opts, :status, "active")

      if status in @goal_statuses do
        params =
          %{
            "threadId" => thread_id,
            "objective" => objective,
            "status" => status
          }
          |> maybe_put_token_budget(token_budget)

        send_goal_update(port, params)
      else
        {:error, {:unsupported_goal_status, status}}
      end
    end
  end

  @spec set_goal_status(session(), String.t()) :: :ok | {:error, term()}
  def set_goal_status(%{port: port, thread_id: thread_id}, status)
      when is_binary(thread_id) and status in @goal_statuses do
    send_goal_update(port, %{"threadId" => thread_id, "status" => status})
  end

  def set_goal_status(%{thread_id: thread_id}, status) when is_binary(thread_id) do
    {:error, {:unsupported_goal_status, status}}
  end

  defp send_goal_update(port, params) do
    send_message(port, %{
      "method" => "thread/goal/set",
      "id" => @thread_goal_set_id,
      "params" => params
    })

    case await_response(port, @thread_goal_set_id) do
      {:ok, %{"goal" => _goal}} -> :ok
      {:ok, _response} -> :ok
      other -> other
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  @spec capability_diagnostics(session()) :: {:ok, map()}
  def capability_diagnostics(%{port: port, thread_id: thread_id, workspace: workspace})
      when is_port(port) and is_binary(thread_id) and is_binary(workspace) do
    plugin_inventory = plugin_inventory(port, workspace)
    mcp_inventory = mcp_inventory(port, thread_id)

    runtime_probe =
      capability_runtime_probe(
        port,
        thread_id,
        plugin_inventory,
        mcp_server_usable?(mcp_inventory, "node_repl", ["js"])
      )

    playwright_probe =
      playwright_runtime_probe(
        port,
        thread_id,
        mcp_server_usable?(mcp_inventory, "playwright", @required_playwright_tools)
      )

    {:ok, CapabilityDiagnostics.resolve(public_plugin_inventory(plugin_inventory), runtime_probe, playwright_probe)}
  end

  defp plugin_inventory(port, workspace) do
    send_message(port, %{
      "method" => "plugin/list",
      "id" => @plugin_list_id,
      "params" => %{"cwds" => [workspace]}
    })

    case await_response(port, @plugin_list_id, @capability_probe_timeout_ms) do
      {:ok, %{"marketplaces" => marketplaces}} when is_list(marketplaces) ->
        plugins = Enum.flat_map(marketplaces, &Map.get(&1, "plugins", []))

        %{
          browser: plugin_state(plugins, "browser@openai-bundled"),
          computer_use: plugin_state(plugins, "computer-use@openai-bundled")
        }

      _other ->
        unknown_plugin_inventory()
    end
  end

  defp plugin_state(plugins, plugin_id) do
    case Enum.find(plugins, &(Map.get(&1, "id") == plugin_id)) do
      %{} = plugin ->
        %{
          installed: Map.get(plugin, "installed"),
          enabled: Map.get(plugin, "enabled"),
          path: get_in(plugin, ["source", "path"])
        }

      nil ->
        %{installed: false, enabled: false, path: nil}
    end
  end

  defp unknown_plugin_inventory do
    unknown = %{installed: nil, enabled: nil, path: nil}
    %{browser: unknown, computer_use: unknown}
  end

  defp public_plugin_inventory(inventory) do
    Map.new(inventory, fn {name, state} ->
      {name, Map.take(state, [:installed, :enabled])}
    end)
  end

  defp mcp_inventory(port, thread_id) do
    send_message(port, %{
      "method" => "mcpServerStatus/list",
      "id" => @mcp_status_id,
      "params" => %{
        "threadId" => thread_id,
        "detail" => "toolsAndAuthOnly",
        "limit" => 100
      }
    })

    case await_response(port, @mcp_status_id, @capability_probe_timeout_ms) do
      {:ok, %{"data" => servers}} when is_list(servers) -> servers
      _other -> []
    end
  end

  defp mcp_server_usable?(servers, name, required_tools) do
    case Enum.find(servers, &(Map.get(&1, "name") == name)) do
      %{"tools" => tools} when is_map(tools) ->
        Enum.all?(required_tools, &Map.has_key?(tools, &1))

      _other ->
        false
    end
  end

  defp capability_runtime_probe(_port, _thread_id, _plugin_inventory, false),
    do: empty_runtime_probe()

  defp capability_runtime_probe(port, thread_id, plugin_inventory, true) do
    probe = do_capability_runtime_probe(port, thread_id, plugin_inventory)

    if runtime_probe_complete?(plugin_inventory, probe) do
      probe
    else
      do_capability_runtime_probe(port, thread_id, plugin_inventory)
    end
  end

  defp do_capability_runtime_probe(port, thread_id, plugin_inventory) do
    send_message(port, %{
      "method" => "mcpServer/tool/call",
      "id" => @capability_runtime_probe_id,
      "params" => %{
        "server" => "node_repl",
        "threadId" => thread_id,
        "tool" => "js",
        "_meta" => %{
          "x-codex-turn-metadata" => %{
            "session_id" => thread_id,
            "thread_id" => thread_id,
            "thread_source" => "vscode",
            "turn_id" => "symphony-capability-diagnostics"
          }
        },
        "arguments" => %{
          "code" => capability_probe_code(plugin_inventory),
          "title" => "Resolve runtime capabilities"
        }
      }
    })

    case await_response(port, @capability_runtime_probe_id, @capability_probe_timeout_ms) do
      {:ok, %{"isError" => false, "content" => content}} when is_list(content) ->
        decode_runtime_probe(content)

      _other ->
        empty_runtime_probe()
    end
  end

  defp runtime_probe_complete?(plugin_inventory, probe) do
    plugin_runtime_ready?(plugin_inventory.browser, probe.browser_loaded) and
      plugin_runtime_ready?(plugin_inventory.computer_use, probe.computer_use_initialized)
  end

  defp plugin_runtime_ready?(%{installed: true, enabled: true}, ready), do: ready == true
  defp plugin_runtime_ready?(_plugin, _ready), do: true

  defp capability_probe_code(plugin_inventory) do
    browser_path = plugin_client_path(plugin_inventory.browser, "browser-client.mjs")
    computer_use_path = plugin_client_path(plugin_inventory.computer_use, "computer-use-client.mjs")

    """
    var symphonyCapabilityProbe = {
      browser_loaded: false,
      browser_backend_count: 0,
      computer_use_initialized: false,
      computer_use_app_count: 0
    };
    var symphonyBrowserClientPath = #{Jason.encode!(browser_path)};
    var symphonyComputerUseClientPath = #{Jason.encode!(computer_use_path)};
    if (symphonyBrowserClientPath) {
      try {
        var symphonyBrowserModule = await import(symphonyBrowserClientPath);
        await symphonyBrowserModule.setupBrowserRuntime({ globals: globalThis });
        symphonyCapabilityProbe.browser_loaded = true;
        symphonyCapabilityProbe.browser_backend_count = (await agent.browsers.list()).length;
      } catch (_error) {
        symphonyCapabilityProbe.browser_loaded = false;
      }
    }
    if (symphonyComputerUseClientPath) {
      try {
        var symphonyComputerUseModule = await import(symphonyComputerUseClientPath);
        await symphonyComputerUseModule.setupComputerUseRuntime({ globals: globalThis });
        symphonyCapabilityProbe.computer_use_initialized = Boolean(globalThis.sky);
        symphonyCapabilityProbe.computer_use_app_count = (await sky.list_apps()).length;
      } catch (_error) {
        symphonyCapabilityProbe.computer_use_initialized = false;
      }
    }
    nodeRepl.write(JSON.stringify(symphonyCapabilityProbe));
    """
  end

  defp plugin_client_path(%{installed: true, enabled: true, path: path}, filename)
       when is_binary(path) do
    Path.join([path, "scripts", filename])
  end

  defp plugin_client_path(_plugin, _filename), do: nil

  defp decode_runtime_probe(content) do
    with %{"text" => text} when is_binary(text) <- Enum.find(content, &(Map.get(&1, "type") == "text")),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(text) do
      %{
        browser_loaded: Map.get(decoded, "browser_loaded", false),
        browser_backend_count: Map.get(decoded, "browser_backend_count", 0),
        computer_use_initialized: Map.get(decoded, "computer_use_initialized", false),
        computer_use_app_count: Map.get(decoded, "computer_use_app_count", 0)
      }
    else
      _other -> empty_runtime_probe()
    end
  end

  defp empty_runtime_probe do
    %{
      browser_loaded: false,
      browser_backend_count: 0,
      computer_use_initialized: false,
      computer_use_app_count: 0
    }
  end

  defp playwright_runtime_probe(_port, _thread_id, false), do: :not_configured

  defp playwright_runtime_probe(port, thread_id, true) do
    send_message(port, %{
      "method" => "mcpServer/tool/call",
      "id" => @playwright_runtime_probe_id,
      "params" => %{
        "server" => "playwright",
        "threadId" => thread_id,
        "tool" => "browser_tabs",
        "arguments" => %{"action" => "list"}
      }
    })

    case await_response(port, @playwright_runtime_probe_id, @capability_probe_timeout_ms) do
      {:ok, %{"isError" => true}} -> {:error, :backend_start_failed}
      {:ok, %{"content" => content}} when is_list(content) -> :ready
      _other -> {:error, :backend_start_failed}
    end
  end

  defp maybe_put_token_budget(params, token_budget) when is_integer(token_budget) and token_budget > 0 do
    Map.put(params, "tokenBudget", token_budget)
  end

  defp maybe_put_token_budget(params, _token_budget), do: params

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp validate_command_directory(workspace, directory, nil) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, canonical_directory} <- PathSafety.canonicalize(directory),
         true <-
           canonical_directory == canonical_workspace or
             String.starts_with?(canonical_directory <> "/", canonical_workspace <> "/") do
      {:ok, canonical_directory}
    else
      false -> {:error, :proof_directory_outside_workspace}
      {:error, reason} -> {:error, {:proof_directory_invalid, reason}}
    end
  end

  defp validate_command_directory(workspace, directory, worker_host) when is_binary(worker_host) do
    if not String.contains?(directory, ["\n", "\r", <<0>>]) and
         (directory == workspace or String.starts_with?(directory <> "/", String.trim_trailing(workspace, "/") <> "/")),
       do: {:ok, directory},
       else: {:error, :proof_directory_outside_workspace}
  end

  defp start_port(workspace, nil) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(Config.settings!().codex.command)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp remote_launch_command(workspace) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      "exec #{Config.settings!().codex.command}"
    ]
    |> Enum.join(" && ")
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp do_start_session(port, workspace, session_policies, thread_id, dynamic_tools) do
    case send_initialize(port) do
      :ok when is_binary(thread_id) ->
        resume_thread(port, workspace, session_policies, thread_id, dynamic_tools)

      :ok ->
        start_thread(port, workspace, session_policies, dynamic_tools)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resume_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox},
         thread_id,
         dynamic_tools
       ) do
    send_message(port, %{
      "method" => "thread/resume",
      "id" => @thread_resume_id,
      "params" => %{
        "threadId" => thread_id,
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => dynamic_tools
      }
    })

    case await_response(port, @thread_resume_id) do
      {:ok, %{"thread" => %{"id" => ^thread_id}} = response} ->
        with {:ok, sources} <- instruction_sources(response), do: {:ok, thread_id, sources}

      {:ok, %{"thread" => %{"id" => resumed_thread_id}}} ->
        {:error, {:resumed_thread_mismatch, thread_id, resumed_thread_id}}

      {:ok, %{"thread" => thread_payload}} ->
        {:error, {:invalid_thread_payload, thread_payload}}

      other ->
        other
    end
  end

  defp start_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox},
         dynamic_tools
       ) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => dynamic_tools
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, response} ->
        started_thread(response)

      other ->
        other
    end
  end

  defp started_thread(%{"thread" => %{"id" => thread_id}} = response) do
    with {:ok, sources} <- instruction_sources(response), do: {:ok, thread_id, sources}
  end

  defp started_thread(%{"thread" => thread_payload}),
    do: {:error, {:invalid_thread_payload, thread_payload}}

  defp started_thread(response), do: {:error, {:invalid_thread_response, response}}

  defp instruction_sources(%{"instructionSources" => sources}) when is_list(sources), do: {:ok, sources}
  defp instruction_sources(%{"instructionSources" => _sources}), do: {:error, :instruction_sources_malformed}
  defp instruction_sources(_response), do: {:error, :instruction_sources_missing}

  defp start_turn(
         port,
         thread_id,
         prompt,
         issue,
         workspace,
         approval_policy,
         turn_sandbox_policy,
         effort
       ) do
    params =
      %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
      |> maybe_put_effort(effort)

    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => params
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp maybe_put_effort(params, effort) when effort in ~w(low medium high xhigh),
    do: Map.put(params, "effort", effort)

  defp maybe_put_effort(params, _effort), do: params

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests
    )
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, complete_line, timeout_ms, tool_executor, auto_approve_requests)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, data, timeout_ms, tool_executor, auto_approve_requests) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          timeout_ms,
          tool_executor,
          auto_approve_requests
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         auto_approve_requests
       ) do
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
        end
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         approval_mode
       ) do
    authorized =
      case approval_mode do
        {:command_only, authorizer} when is_function(authorizer, 1) -> authorizer.(payload)
        other -> other
      end

    approve_or_require(
      port,
      id,
      if(match?({:command_only, _authorizer}, approval_mode), do: "accept", else: "acceptForSession"),
      payload,
      payload_string,
      on_message,
      metadata,
      authorized
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _not_authorized
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        reply_with_non_interactive_tool_input_answer(
          port,
          id,
          params,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         false
       ) do
    reply_with_non_interactive_tool_input_answer(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata
    )
  end

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp reply_with_non_interactive_tool_input_answer(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata
       ) do
    case tool_request_user_input_unavailable_answers(params) do
      {:ok, answers} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, raw: payload_string, answer: @non_interactive_tool_input_answer},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp tool_request_user_input_unavailable_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_question_id(question) do
          {:ok, question_id} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map}
      _ -> :error
    end
  end

  defp tool_request_user_input_unavailable_answers(_params), do: :error

  defp tool_request_user_input_question_id(%{"id" => question_id}) when is_binary(question_id),
    do: {:ok, question_id}

  defp tool_request_user_input_question_id(_question), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    case tool_request_user_input_approval_option_label(options) do
      nil -> :error
      answer_label -> {:ok, question_id, answer_label}
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp await_response(port, request_id, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    with_timeout_response(port, request_id, timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
