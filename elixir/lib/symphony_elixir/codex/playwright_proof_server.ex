defmodule SymphonyElixir.Codex.PlaywrightProofServer do
  @moduledoc false

  alias SymphonyElixir.PathSafety

  @cache_entry_limit 128
  @startup_timeout_ms 15_000
  @line_bytes 65_536
  @version_pattern ~r/\A\d+\.\d+\.\d+\z/

  @spec with_endpoint(Path.t(), Path.t(), String.t() | nil, (map() | nil -> result)) :: result
        when result: term()
  def with_endpoint(workspace, directory, worker_host, callback)
      when is_binary(workspace) and is_binary(directory) and is_function(callback, 1) do
    cache_root = System.get_env("NPM_CONFIG_CACHE") || Path.join(System.user_home!(), ".npm")

    case resolve_cached_cli(workspace, directory, cache_root) do
      :not_applicable ->
        callback.(nil)

      {:ok, runtime} when is_nil(worker_host) ->
        with_server(runtime, callback)

      {:ok, %{version: version}} ->
        {:error, {:playwright_remote_worker_unsupported, version}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec resolve_cached_cli(Path.t(), Path.t(), Path.t()) ::
          :not_applicable | {:ok, %{cli: Path.t(), version: String.t()}} | {:error, term()}
  def resolve_cached_cli(workspace, directory, cache_root) do
    with {:ok, version} <- locked_playwright_version(workspace, directory),
         {:ok, canonical_cache} <- PathSafety.canonicalize(cache_root) do
      find_cached_cli(canonical_cache, version)
    end
  end

  defp locked_playwright_version(workspace, directory) do
    case nearest_package_lock(workspace, directory) do
      nil ->
        :not_applicable

      lock ->
        read_locked_playwright_version(lock)
    end
  end

  defp read_locked_playwright_version(lock) do
    with {:ok, contents} <- File.read(lock),
         {:ok, payload} <- Jason.decode(contents) do
      packages = payload["packages"] || %{}
      test_version = get_in(packages, ["node_modules/@playwright/test", "version"])
      playwright_version = get_in(packages, ["node_modules/playwright", "version"])
      validate_locked_versions(test_version, playwright_version)
    else
      {:error, _reason} -> {:error, :playwright_lock_invalid}
    end
  end

  defp validate_locked_versions(nil, nil), do: :not_applicable

  defp validate_locked_versions(test_version, playwright_version) when is_binary(playwright_version) do
    cond do
      not Regex.match?(@version_pattern, playwright_version) ->
        {:error, :playwright_lock_version_invalid}

      is_binary(test_version) and test_version != playwright_version ->
        {:error, {:playwright_lock_version_mismatch, test_version, playwright_version}}

      true ->
        {:ok, playwright_version}
    end
  end

  defp validate_locked_versions(_test_version, _playwright_version),
    do: {:error, :playwright_lock_version_invalid}

  defp nearest_package_lock(workspace, directory) do
    workspace = Path.expand(workspace)
    directory = Path.expand(directory)

    if directory == workspace or String.starts_with?(directory <> "/", workspace <> "/") do
      directory
      |> Stream.unfold(&lock_candidate(&1, workspace))
      |> Enum.find(&File.regular?/1)
    end
  end

  defp lock_candidate(nil, _workspace), do: nil

  defp lock_candidate(current, workspace) do
    next = if current == workspace, do: nil, else: Path.dirname(current)
    {Path.join(current, "package-lock.json"), next}
  end

  defp find_cached_cli(cache_root, version) do
    entries =
      cache_root
      |> Path.join("_npx")
      |> File.ls()
      |> case do
        {:ok, names} -> names |> Enum.sort() |> Enum.take(@cache_entry_limit)
        {:error, _reason} -> []
      end

    candidates =
      Enum.map(entries, fn entry ->
        Path.join([cache_root, "_npx", entry, "node_modules"])
      end)

    case Enum.find_value(candidates, &valid_cached_cli(&1, cache_root, version)) do
      nil ->
        if Enum.any?(candidates, &playwright_version?(&1, version)),
          do: {:error, {:playwright_cache_version_mismatch, version}},
          else: {:error, {:playwright_cache_unavailable, version}}

      cli ->
        {:ok, %{cli: cli, version: version}}
    end
  end

  defp valid_cached_cli(node_modules, cache_root, version) do
    cli = Path.join([node_modules, "playwright", "cli.js"])

    with true <- cache_lock_valid?(Path.dirname(node_modules), version),
         true <- playwright_version?(node_modules, version),
         true <- package_version?(Path.join(node_modules, "playwright-core"), "playwright-core", version),
         true <- File.regular?(cli),
         {:ok, canonical_cli} <- PathSafety.canonicalize(cli),
         true <- String.starts_with?(canonical_cli <> "/", cache_root <> "/") do
      canonical_cli
    else
      _ -> nil
    end
  end

  defp cache_lock_valid?(cache_entry, version) do
    with {:ok, contents} <- File.read(Path.join(cache_entry, "package-lock.json")),
         {:ok, %{"packages" => packages}} <- Jason.decode(contents),
         %{
           "version" => ^version,
           "resolved" => "https://registry.npmjs.org/playwright/-/playwright-" <> archive,
           "integrity" => "sha512-" <> playwright_integrity,
           "dependencies" => %{"playwright-core" => ^version}
         } <- packages["node_modules/playwright"],
         true <- archive == "#{version}.tgz",
         true <- byte_size(playwright_integrity) > 20,
         %{
           "version" => ^version,
           "resolved" => "https://registry.npmjs.org/playwright-core/-/playwright-core-" <> core_archive,
           "integrity" => "sha512-" <> core_integrity
         } <- packages["node_modules/playwright-core"],
         true <- core_archive == "#{version}.tgz",
         true <- byte_size(core_integrity) > 20 do
      true
    else
      _ -> false
    end
  end

  defp playwright_version?(node_modules, version) do
    package_version?(Path.join(node_modules, "playwright"), "playwright", version)
  end

  defp package_version?(directory, name, version) do
    with {:ok, contents} <- File.read(Path.join(directory, "package.json")),
         {:ok, %{"name" => ^name, "version" => ^version}} <- Jason.decode(contents) do
      true
    else
      _ -> false
    end
  end

  defp with_server(%{cli: cli, version: version}, callback) do
    with {:ok, port, endpoint} <- start_server(cli, version) do
      try do
        callback.(%{
          endpoint: endpoint,
          path: "playwright_headless",
          provenance: "npm_playwright_offline",
          version: version
        })
      after
        stop_server(port)
      end
    end
  end

  defp start_server(cli, version) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    endpoint_path = "/symphony-#{token}"

    with node when is_binary(node) <- System.find_executable("node"),
         env when is_binary(env) <- System.find_executable("env") do
      args =
        clean_environment_args() ++
          [
            node,
            cli,
            "run-server",
            "--host",
            "127.0.0.1",
            "--port",
            "0",
            "--path",
            endpoint_path,
            "--max-clients",
            "1"
          ]

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(env)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: Enum.map(args, &String.to_charlist/1),
            line: @line_bytes
          ]
        )

      await_endpoint(port, endpoint_path, version, "", System.monotonic_time(:millisecond))
    else
      _ -> {:error, :playwright_server_runtime_unavailable}
    end
  end

  defp clean_environment_args do
    ["-i"] ++
      Enum.flat_map(
        [
          {"HOME", System.user_home!()},
          {"PATH", System.get_env("PATH")},
          {"TMPDIR", System.get_env("TMPDIR")},
          {"LANG", System.get_env("LANG")},
          {"PLAYWRIGHT_BROWSERS_PATH", System.get_env("PLAYWRIGHT_BROWSERS_PATH")}
        ],
        fn
          {_name, nil} -> []
          {name, value} -> ["#{name}=#{value}"]
        end
      )
  end

  defp await_endpoint(port, endpoint_path, version, buffer, started_at) do
    elapsed = System.monotonic_time(:millisecond) - started_at
    remaining = max(@startup_timeout_ms - elapsed, 0)

    receive do
      {^port, {:data, {_line_kind, data}}} ->
        buffer = keep_startup_tail(buffer <> data)

        case parse_endpoint(buffer, endpoint_path) do
          {:ok, endpoint} -> {:ok, port, endpoint}
          :pending -> await_endpoint(port, endpoint_path, version, buffer, started_at)
        end

      {^port, {:exit_status, status}} ->
        {:error, {:playwright_server_start_failed, version, status}}
    after
      remaining ->
        stop_server(port)
        {:error, {:playwright_server_start_timeout, version}}
    end
  end

  defp parse_endpoint(output, endpoint_path) do
    pattern = ~r/ws:\/\/127\.0\.0\.1:(\d+)#{Regex.escape(endpoint_path)}/

    case Regex.run(pattern, output, capture: :all_but_first) do
      [port] ->
        case Integer.parse(port) do
          {number, ""} when number in 1..65_535 ->
            {:ok, "ws://127.0.0.1:#{number}#{endpoint_path}"}

          _ ->
            :pending
        end

      _ ->
        :pending
    end
  end

  defp keep_startup_tail(output) when byte_size(output) <= @line_bytes, do: output

  defp keep_startup_tail(output) do
    binary_part(output, byte_size(output) - @line_bytes, @line_bytes)
  end

  defp stop_server(port) when is_port(port) do
    if :erlang.port_info(port) != :undefined do
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end
end
