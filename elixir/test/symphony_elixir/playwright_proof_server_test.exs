defmodule SymphonyElixir.PlaywrightProofServerTest do
  use ExUnit.Case

  alias SymphonyElixir.Codex.PlaywrightProofServer

  setup do
    original_cache = System.get_env("NPM_CONFIG_CACHE")

    on_exit(fn ->
      if original_cache,
        do: System.put_env("NPM_CONFIG_CACHE", original_cache),
        else: System.delete_env("NPM_CONFIG_CACHE")
    end)

    :ok
  end

  test "resolves an exact Playwright version from the proof lockfile and bounded npm cache" do
    root = test_root("exact-version")
    workspace = Path.join(root, "workspace")
    directory = Path.join(workspace, "test/browser")
    cache_root = Path.join(root, "npm-cache")
    write_lock!(directory, "1.59.1")
    cli = write_cached_playwright!(cache_root, "cache-entry", "1.59.1")
    {:ok, cli} = SymphonyElixir.PathSafety.canonicalize(cli)

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, %{cli: ^cli, version: "1.59.1"}} =
             PlaywrightProofServer.resolve_cached_cli(workspace, directory, cache_root)
  end

  test "fails closed when the cached Playwright core version does not match" do
    root = test_root("mismatched-core")
    workspace = Path.join(root, "workspace")
    directory = Path.join(workspace, "test/browser")
    cache_root = Path.join(root, "npm-cache")
    write_lock!(directory, "1.59.1")
    write_cached_playwright!(cache_root, "cache-entry", "1.59.1", "1.60.0")

    on_exit(fn -> File.rm_rf(root) end)

    assert {:error, {:playwright_cache_version_mismatch, "1.59.1"}} =
             PlaywrightProofServer.resolve_cached_cli(workspace, directory, cache_root)
  end

  test "rejects a cached CLI that escapes the npm cache through a symlink" do
    root = test_root("symlink-escape")
    workspace = Path.join(root, "workspace")
    directory = Path.join(workspace, "test/browser")
    cache_root = Path.join(root, "npm-cache")
    outside = Path.join(root, "outside")
    write_lock!(directory, "1.59.1")
    outside_cli = write_cached_playwright!(outside, "package", "1.59.1")
    cache_entry = Path.join([cache_root, "_npx", "cache-entry", "node_modules"])
    File.mkdir_p!(cache_entry)
    File.ln_s!(Path.dirname(Path.dirname(outside_cli)), Path.join(cache_entry, "playwright"))
    File.ln_s!(Path.join(Path.dirname(Path.dirname(outside_cli)), "playwright-core"), Path.join(cache_entry, "playwright-core"))

    on_exit(fn -> File.rm_rf(root) end)

    assert {:error, {:playwright_cache_unavailable, "1.59.1"}} =
             PlaywrightProofServer.resolve_cached_cli(workspace, directory, cache_root)
  end

  test "starts the exact cached runtime and exposes only safe browser metadata" do
    root = test_root("server-start")
    workspace = Path.join(root, "workspace")
    directory = Path.join(workspace, "test/browser")
    cache_root = Path.join(root, "npm-cache")
    write_lock!(directory, "1.59.1")

    cli =
      write_cached_playwright!(cache_root, "cache-entry", "1.59.1")

    File.write!(
      cli,
      """
      const net = require("net");
      const pathIndex = process.argv.indexOf("--path");
      const endpointPath = process.argv[pathIndex + 1];
      const server = net.createServer(() => {});
      server.listen(0, "127.0.0.1", () => {
        const address = server.address();
        console.log(`Listening on ws://127.0.0.1:${address.port}${endpointPath}`);
      });
      """
    )

    System.put_env("NPM_CONFIG_CACHE", cache_root)
    on_exit(fn -> File.rm_rf(root) end)

    assert :proof_complete =
             PlaywrightProofServer.with_endpoint(workspace, directory, nil, fn runtime ->
               assert runtime.path == "playwright_headless"
               assert runtime.provenance == "npm_playwright_offline"
               assert runtime.version == "1.59.1"
               assert URI.parse(runtime.endpoint).host == "127.0.0.1"
               refute Map.has_key?(runtime, :session_id)
               :proof_complete
             end)
  end

  test "does not start a browser server for a proof without Playwright" do
    root = test_root("not-applicable")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    System.put_env("NPM_CONFIG_CACHE", Path.join(root, "npm-cache"))
    on_exit(fn -> File.rm_rf(root) end)

    assert :ordinary_proof =
             PlaywrightProofServer.with_endpoint(workspace, workspace, nil, fn runtime ->
               assert is_nil(runtime)
               :ordinary_proof
             end)
  end

  test "fails closed for remote workers and missing exact runtimes" do
    root = test_root("unavailable")
    workspace = Path.join(root, "workspace")
    directory = Path.join(workspace, "test/browser")
    cache_root = Path.join(root, "npm-cache")
    write_lock!(directory, "1.59.1")
    write_cached_playwright!(cache_root, "cache-entry", "1.59.1")
    System.put_env("NPM_CONFIG_CACHE", cache_root)
    on_exit(fn -> File.rm_rf(root) end)

    assert {:error, {:playwright_remote_worker_unsupported, "1.59.1"}} =
             PlaywrightProofServer.with_endpoint(workspace, directory, "worker.example", fn _runtime ->
               flunk("remote proof must not receive a local endpoint")
             end)

    File.rm_rf!(Path.join(cache_root, "_npx"))

    assert {:error, {:playwright_cache_unavailable, "1.59.1"}} =
             PlaywrightProofServer.with_endpoint(workspace, directory, nil, fn _runtime ->
               flunk("missing runtime must not execute the proof")
             end)
  end

  test "reports an actionable cached runtime startup failure" do
    root = test_root("server-failure")
    workspace = Path.join(root, "workspace")
    directory = Path.join(workspace, "test/browser")
    cache_root = Path.join(root, "npm-cache")
    write_lock!(directory, "1.59.1")
    cli = write_cached_playwright!(cache_root, "cache-entry", "1.59.1")
    File.write!(cli, "process.exit(7);\n")
    System.put_env("NPM_CONFIG_CACHE", cache_root)
    on_exit(fn -> File.rm_rf(root) end)

    assert {:error, {:playwright_server_start_failed, "1.59.1", 7}} =
             PlaywrightProofServer.with_endpoint(workspace, directory, nil, fn _runtime ->
               flunk("failed runtime must not execute the proof")
             end)
  end

  defp write_lock!(directory, version) do
    File.mkdir_p!(directory)

    File.write!(
      Path.join(directory, "package-lock.json"),
      Jason.encode!(%{
        "lockfileVersion" => 3,
        "packages" => %{
          "node_modules/@playwright/test" => %{"version" => version},
          "node_modules/playwright" => %{"version" => version}
        }
      })
    )
  end

  defp write_cached_playwright!(cache_root, entry, version, core_version \\ nil) do
    node_modules = Path.join([cache_root, "_npx", entry, "node_modules"])
    playwright = Path.join(node_modules, "playwright")
    playwright_core = Path.join(node_modules, "playwright-core")
    File.mkdir_p!(playwright)
    File.mkdir_p!(playwright_core)
    File.write!(Path.join(playwright, "package.json"), Jason.encode!(%{"name" => "playwright", "version" => version}))

    File.write!(
      Path.join(playwright_core, "package.json"),
      Jason.encode!(%{"name" => "playwright-core", "version" => core_version || version})
    )

    File.write!(
      Path.join(Path.dirname(node_modules), "package-lock.json"),
      Jason.encode!(%{
        "lockfileVersion" => 3,
        "packages" => %{
          "node_modules/playwright" => %{
            "version" => version,
            "resolved" => "https://registry.npmjs.org/playwright/-/playwright-#{version}.tgz",
            "integrity" => "sha512-#{String.duplicate("p", 32)}",
            "dependencies" => %{"playwright-core" => version}
          },
          "node_modules/playwright-core" => %{
            "version" => core_version || version,
            "resolved" => "https://registry.npmjs.org/playwright-core/-/playwright-core-#{core_version || version}.tgz",
            "integrity" => "sha512-#{String.duplicate("c", 32)}"
          }
        }
      })
    )

    cli = Path.join(playwright, "cli.js")
    File.write!(cli, "")
    cli
  end

  defp test_root(label) do
    Path.join(
      System.tmp_dir!(),
      "symphony-playwright-proof-server-#{label}-#{System.unique_integer([:positive])}"
    )
  end
end
