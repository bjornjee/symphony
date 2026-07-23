defmodule SymphonyElixir.CapabilityDiagnosticsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.CapabilityDiagnostics

  test "selects headless Playwright when Browser is enabled without a session backend" do
    report =
      CapabilityDiagnostics.resolve(
        %{
          browser: %{installed: true, enabled: true},
          computer_use: %{installed: true, enabled: true}
        },
        %{
          browser_loaded: true,
          browser_backend_count: 0,
          computer_use_initialized: true,
          computer_use_app_count: 24
        },
        :ready
      )

    assert report.browser.configured
    refute report.browser.usable
    assert report.browser.code == "session_backend_unavailable"
    assert report.computer_use.usable
    assert report.computer_use.app_count == 24
    assert report.browser_path.selected == "playwright_headless"
    assert report.browser_path.provenance == "codex_global_mcp"
    assert report.browser_path.code == "browser_session_backend_unavailable"
    assert report.browser_path.action =~ "Playwright"
  end

  test "prefers a runtime-usable Codex Browser backend" do
    report =
      CapabilityDiagnostics.resolve(
        %{
          browser: %{installed: true, enabled: true},
          computer_use: %{installed: true, enabled: true}
        },
        %{
          browser_loaded: true,
          browser_backend_count: 1,
          computer_use_initialized: true,
          computer_use_app_count: 3
        },
        :ready
      )

    assert report.browser.usable
    assert report.browser_path.selected == "codex_browser"
    assert report.browser_path.provenance == "codex_global_browser_plugin"
    assert report.browser_path.code == "ready"
  end

  test "reports actionable unavailability without exposing backend details" do
    report =
      CapabilityDiagnostics.resolve(
        %{
          browser: %{installed: true, enabled: false},
          computer_use: %{installed: false, enabled: false}
        },
        %{
          browser_loaded: false,
          browser_backend_count: 0,
          computer_use_initialized: false,
          computer_use_app_count: 0
        },
        {:error, :backend_start_failed}
      )

    assert report.browser.code == "disabled"
    assert report.computer_use.code == "not_installed"
    assert report.playwright.code == "backend_unavailable"
    assert report.browser_path.selected == "unavailable"
    assert report.browser_path.action =~ "Playwright"
    refute inspect(report) =~ "session_id"
    refute inspect(report) =~ ".sock"
  end

  test "reports runtime initialization failures for configured plugins" do
    report =
      CapabilityDiagnostics.resolve(
        %{
          browser: %{installed: true, enabled: true},
          computer_use: %{installed: true, enabled: true}
        },
        %{
          browser_loaded: false,
          browser_backend_count: 0,
          computer_use_initialized: false,
          computer_use_app_count: 0
        },
        :ready
      )

    assert report.browser.code == "runtime_initialization_failed"
    assert report.computer_use.code == "runtime_initialization_failed"
    assert report.browser_path.code == "browser_runtime_initialization_failed"
  end

  test "distinguishes disabled Computer Use from an absent plugin" do
    report =
      CapabilityDiagnostics.resolve(
        %{
          browser: %{installed: false, enabled: false},
          computer_use: %{installed: true, enabled: false}
        },
        %{},
        :not_configured
      )

    assert report.browser.code == "not_installed"
    assert report.computer_use.code == "disabled"
  end

  test "reports unknown plugin configuration without guessing enablement" do
    report = CapabilityDiagnostics.resolve(%{}, %{}, :not_configured)

    assert report.browser.code == "configuration_unknown"
    assert report.computer_use.code == "configuration_unknown"
    assert report.browser_path.selected == "unavailable"
  end
end
