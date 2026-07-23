defmodule SymphonyElixir.Codex.CapabilityDiagnostics do
  @moduledoc """
  Classifies configured Codex capabilities separately from runtime-usable backends.
  """

  @browser_provenance "codex_global_browser_plugin"
  @computer_use_provenance "codex_global_computer_use_plugin"
  @playwright_provenance "codex_global_mcp"

  @spec resolve(map(), map(), :ready | :not_configured | {:error, atom()}) :: map()
  def resolve(plugin_inventory, runtime_probe, playwright_probe)
      when is_map(plugin_inventory) and is_map(runtime_probe) do
    browser = browser_diagnostic(Map.get(plugin_inventory, :browser, %{}), runtime_probe)
    computer_use = computer_use_diagnostic(Map.get(plugin_inventory, :computer_use, %{}), runtime_probe)
    playwright = playwright_diagnostic(playwright_probe)

    %{
      browser: browser,
      computer_use: computer_use,
      playwright: playwright,
      browser_path: select_browser_path(browser, playwright)
    }
  end

  defp browser_diagnostic(plugin, runtime_probe) do
    loaded = Map.get(runtime_probe, :browser_loaded, false)
    backend_count = Map.get(runtime_probe, :browser_backend_count, 0)

    case plugin_status(plugin) do
      :not_installed ->
        diagnostic(
          false,
          false,
          "not_installed",
          "Codex Browser is not installed in the effective global plugin configuration.",
          "Install and enable the global Browser plugin before starting Symphony.",
          @browser_provenance
        )

      :disabled ->
        diagnostic(
          false,
          false,
          "disabled",
          "Codex Browser is disabled in the effective global plugin configuration.",
          "Enable the global Browser plugin before starting Symphony if Browser is required.",
          @browser_provenance
        )

      :configured ->
        browser_runtime_diagnostic(loaded, backend_count)

      :unknown ->
        diagnostic(
          false,
          false,
          "configuration_unknown",
          "Symphony could not determine the effective global Browser configuration.",
          "Check Codex plugin status and app-server startup diagnostics.",
          @browser_provenance
        )
    end
  end

  defp browser_runtime_diagnostic(true, backend_count)
       when is_integer(backend_count) and backend_count > 0 do
    diagnostic(
      true,
      true,
      "ready",
      "Codex Browser is configured and has a backend bound to this app-server session.",
      nil,
      @browser_provenance
    )
  end

  defp browser_runtime_diagnostic(true, _backend_count) do
    diagnostic(
      true,
      false,
      "session_backend_unavailable",
      "Codex Browser is enabled, but no backend is bound to this standalone app-server session.",
      "Use headless Playwright for automated UI verification. Browser backend delegation requires upstream Codex app-server support.",
      @browser_provenance
    )
  end

  defp browser_runtime_diagnostic(_loaded, _backend_count) do
    diagnostic(
      true,
      false,
      "runtime_initialization_failed",
      "Codex Browser is enabled, but its runtime could not be initialized for this app-server session.",
      "Check the installed Browser plugin version and Codex app-server logs, then use Playwright when available.",
      @browser_provenance
    )
  end

  defp computer_use_diagnostic(plugin, runtime_probe) do
    initialized = Map.get(runtime_probe, :computer_use_initialized, false)
    app_count = Map.get(runtime_probe, :computer_use_app_count, 0)

    base =
      case plugin_status(plugin) do
        :not_installed ->
          diagnostic(
            false,
            false,
            "not_installed",
            "Computer Use is not installed in the effective global plugin configuration.",
            "Install and enable the global Computer Use plugin before starting Symphony.",
            @computer_use_provenance
          )

        :disabled ->
          diagnostic(
            false,
            false,
            "disabled",
            "Computer Use is disabled in the effective global plugin configuration.",
            "Enable the global Computer Use plugin before starting Symphony if desktop automation is required.",
            @computer_use_provenance
          )

        :configured ->
          computer_use_runtime_diagnostic(initialized, app_count)

        :unknown ->
          diagnostic(
            false,
            false,
            "configuration_unknown",
            "Symphony could not determine the effective global Computer Use configuration.",
            "Check Codex plugin status and app-server startup diagnostics.",
            @computer_use_provenance
          )
      end

    Map.put(base, :app_count, if(base.usable, do: app_count, else: 0))
  end

  defp computer_use_runtime_diagnostic(true, app_count)
       when is_integer(app_count) and app_count > 0 do
    diagnostic(
      true,
      true,
      "ready",
      "Computer Use is inherited from the global Codex plugin and responded to runtime discovery.",
      nil,
      @computer_use_provenance
    )
  end

  defp computer_use_runtime_diagnostic(_initialized, _app_count) do
    diagnostic(
      true,
      false,
      "runtime_initialization_failed",
      "Computer Use is enabled, but its runtime discovery call failed or returned no available apps.",
      "Confirm the local Computer Use service is running and macOS permissions are granted.",
      @computer_use_provenance
    )
  end

  defp playwright_diagnostic(:ready) do
    diagnostic(
      true,
      true,
      "ready",
      "The inherited headless Playwright MCP has a responsive browser backend.",
      nil,
      @playwright_provenance
    )
  end

  defp playwright_diagnostic(:not_configured) do
    diagnostic(
      false,
      false,
      "not_configured",
      "The headless Playwright MCP is not configured with the required UI-verification tools.",
      "Enable the global Playwright MCP with tabs, navigate, snapshot, and screenshot tools.",
      @playwright_provenance
    )
  end

  defp playwright_diagnostic({:error, _reason}) do
    diagnostic(
      true,
      false,
      "backend_unavailable",
      "The headless Playwright MCP is configured, but its browser backend did not respond.",
      "Check the Playwright MCP startup and installed Chromium runtime, then retry visual verification.",
      @playwright_provenance
    )
  end

  defp select_browser_path(%{usable: true}, _playwright) do
    %{
      selected: "codex_browser",
      provenance: @browser_provenance,
      code: "ready",
      message: "Use the Codex Browser backend bound to this app-server session.",
      action: "Use Browser for interactive browser work and preserve its session security checks."
    }
  end

  defp select_browser_path(browser, %{usable: true}) do
    %{
      selected: "playwright_headless",
      provenance: @playwright_provenance,
      code: browser_path_code(browser.code),
      message: "Use deterministic headless Playwright because Codex Browser is not runtime-usable in this session.",
      action: "Use the inherited Playwright MCP for automated UI rendering, inspection, screenshots, and behavior checks."
    }
  end

  defp select_browser_path(browser, playwright) do
    %{
      selected: "unavailable",
      provenance: nil,
      code: "no_runtime_browser_backend",
      message: "Neither Codex Browser nor headless Playwright has a runtime-usable backend.",
      action: "#{browser.action} #{playwright.action}" |> String.trim()
    }
  end

  defp browser_path_code("session_backend_unavailable"), do: "browser_session_backend_unavailable"
  defp browser_path_code(code), do: "browser_#{code}"

  defp plugin_status(%{installed: false}), do: :not_installed
  defp plugin_status(%{enabled: false}), do: :disabled
  defp plugin_status(%{installed: true, enabled: true}), do: :configured
  defp plugin_status(_plugin), do: :unknown

  defp diagnostic(configured, usable, code, message, action, provenance) do
    %{
      configured: configured,
      usable: usable,
      code: code,
      message: message,
      action: action,
      provenance: provenance
    }
  end
end
