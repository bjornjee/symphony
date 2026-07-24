defmodule SymphonyElixir.RepositoryFingerprint do
  @moduledoc """
  Captures the bounded repository identity and worktree state used by preactivation.
  """

  alias SymphonyElixir.SSH

  @max_snapshot_bytes 4_194_304
  @max_untracked_files 256
  @max_untracked_path_bytes 65_536
  @max_untracked_file_bytes 1_048_576
  @max_untracked_content_bytes 4_194_304
  @command_timeout_ms 10_000
  @engine_artifacts [
    ".symphony/execution-manifest.json",
    ".symphony/codex-thread.json",
    ".symphony/run-audit.jsonl",
    ".symphony/run-audit.md",
    ".symphony/first-useful-edit",
    ".symphony/workpad.md",
    ".symphony/plan-candidate-*.json",
    ".symphony/plan-review-*.json",
    ".symphony/execution-plan.json",
    ".symphony/task-classification.json",
    ".symphony/completion-evidence.json",
    ".symphony/authorities/**"
  ]

  @type snapshot :: %{
          origin: String.t(),
          base_sha: String.t(),
          digest: String.t(),
          clean: boolean(),
          status_digest: String.t(),
          staged_digest: String.t(),
          unstaged_digest: String.t(),
          untracked_digest: String.t()
        }

  @spec capture(Path.t(), String.t() | nil) :: {:ok, snapshot()} | {:error, term()}
  def capture(workspace, worker_host \\ nil) when is_binary(workspace) do
    capture(workspace, worker_host, [])
  end

  @spec capture(Path.t(), String.t() | nil, keyword()) :: {:ok, snapshot()} | {:error, term()}
  def capture(workspace, worker_host, opts) when is_binary(workspace) and is_list(opts) do
    runner = Keyword.get(opts, :git_runner, &git(workspace, worker_host, &1))

    untracked_sizer =
      Keyword.get(opts, :untracked_sizer, &untracked_sizes(workspace, worker_host, &1))

    command_timeout_ms = Keyword.get(opts, :command_timeout_ms, @command_timeout_ms)

    timed_runner = fn args ->
      run_with_timeout(fn -> runner.(args) end, command_timeout_ms, args)
    end

    timed_sizer = fn paths ->
      run_with_timeout(fn -> untracked_sizer.(paths) end, command_timeout_ms, :untracked_size)
    end

    commands = [
      origin: ["config", "--get", "remote.origin.url"],
      base_sha: ["rev-parse", "HEAD"],
      status: status_args(),
      unstaged: diff_args([]),
      staged: diff_args(["--cached"]),
      untracked_paths: untracked_args()
    ]

    with {:ok, captured} <- parallel_git(commands, timed_runner, command_timeout_ms),
         origin <- captured.origin,
         base_sha <- captured.base_sha,
         status <- captured.status,
         unstaged <- captured.unstaged,
         staged <- captured.staged,
         untracked_paths <- captured.untracked_paths,
         :ok <- bounded(status, "status"),
         :ok <- bounded(unstaged, "unstaged diff"),
         :ok <- bounded(staged, "staged diff"),
         :ok <- bounded(untracked_paths, "untracked paths"),
         {:ok, untracked} <-
           fingerprint_untracked(untracked_paths, timed_runner, timed_sizer) do
      origin = String.trim(origin)
      base_sha = String.trim(base_sha)

      if origin == "" or not Regex.match?(~r/^[a-f0-9]{40,64}$/, base_sha) do
        {:error, :invalid_repository_identity}
      else
        digest =
          sha256([
            base_sha,
            <<0>>,
            status,
            <<0>>,
            unstaged,
            <<0>>,
            staged,
            <<0>>,
            untracked
          ])

        {:ok,
         %{
           origin: origin,
           base_sha: base_sha,
           digest: digest,
           clean: String.trim(status) == "" and staged == "" and unstaged == "",
           status_digest: sha256(status),
           staged_digest: sha256(staged),
           unstaged_digest: sha256(unstaged),
           untracked_digest: sha256(untracked)
         }}
      end
    end
  end

  defp fingerprint_untracked("", _runner, _sizer), do: {:ok, ""}

  defp fingerprint_untracked(payload, runner, sizer) do
    paths = payload |> String.split(<<0>>, trim: true) |> Enum.sort()

    with :ok <- validate_untracked_paths(paths, payload),
         {:ok, sizes} <- sizer.(paths),
         :ok <- validate_untracked_sizes(paths, sizes),
         {:ok, hashes} <- runner.(["hash-object", "--no-filters", "--" | paths]),
         hash_lines <- String.split(hashes, "\n", trim: true),
         true <- length(hash_lines) == length(paths) || {:error, :untracked_hash_count_mismatch},
         true <-
           Enum.all?(hash_lines, &Regex.match?(~r/^[a-f0-9]{40,64}$/, &1)) ||
             {:error, :invalid_untracked_hash} do
      {:ok,
       paths
       |> Enum.zip(hash_lines)
       |> Enum.map_join("", fn {path, hash} -> path <> <<0>> <> hash <> <<0>> end)}
    end
  end

  defp validate_untracked_paths(paths, payload) do
    cond do
      length(paths) > @max_untracked_files ->
        {:error, {:too_many_untracked_files, @max_untracked_files}}

      byte_size(payload) > @max_untracked_path_bytes ->
        {:error, {:untracked_paths_too_large, @max_untracked_path_bytes}}

      Enum.any?(paths, &(Path.type(&1) != :relative or ".." in Path.split(&1))) ->
        {:error, :unsafe_untracked_path}

      true ->
        :ok
    end
  end

  defp validate_untracked_sizes(paths, sizes)
       when is_list(sizes) and length(paths) == length(sizes) do
    paths
    |> Enum.zip(sizes)
    |> Enum.reduce_while({:ok, 0}, fn
      {path, size}, {:ok, total} when is_integer(size) and size >= 0 ->
        cond do
          size > @max_untracked_file_bytes ->
            {:halt, {:error, {:untracked_file_too_large, path, @max_untracked_file_bytes}}}

          total + size > @max_untracked_content_bytes ->
            {:halt, {:error, {:untracked_content_too_large, @max_untracked_content_bytes}}}

          true ->
            {:cont, {:ok, total + size}}
        end

      _invalid, _total ->
        {:halt, {:error, :invalid_untracked_file_size}}
    end)
    |> case do
      {:ok, _total} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_untracked_sizes(_paths, _sizes), do: {:error, :untracked_size_count_mismatch}

  defp parallel_git(commands, runner, timeout_ms) do
    commands
    |> Task.async_stream(
      fn {key, args} -> {key, runner.(args)} end,
      max_concurrency: length(commands),
      ordered: true,
      timeout: timeout_ms + 100,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {key, {:ok, output}}}, {:ok, captured} ->
        {:cont, {:ok, Map.put(captured, key, output)}}

      {:ok, {_key, {:error, _reason} = error}}, _captured ->
        {:halt, error}

      {:exit, reason}, _captured ->
        {:halt, {:error, {:git_capture_task_failed, reason}}}
    end)
  end

  defp run_with_timeout(fun, timeout_ms, command) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, {:git_command_timeout, command}}
      {:exit, reason} -> {:error, {:git_command_failed, command, reason}}
    end
  end

  defp untracked_sizes(workspace, nil, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, sizes} ->
      case File.stat(Path.join(workspace, path)) do
        {:ok, %{size: size}} -> {:cont, {:ok, [size | sizes]}}
        {:error, reason} -> {:halt, {:error, {:untracked_file_stat_failed, path, reason}}}
      end
    end)
    |> case do
      {:ok, sizes} -> {:ok, Enum.reverse(sizes)}
      {:error, _reason} = error -> error
    end
  end

  defp untracked_sizes(workspace, worker_host, paths) when is_binary(worker_host) do
    commands =
      Enum.map(paths, fn path ->
        "wc -c < " <> shell_escape(Path.join(workspace, path))
      end)

    case SSH.run(worker_host, Enum.join(commands, " && "), stderr_to_stdout: true) do
      {:ok, {output, 0}} ->
        sizes =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_untracked_size/1)

        {:ok, sizes}

      {:ok, {output, status}} ->
        {:error, {:untracked_file_stat_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, {:untracked_file_stat_failed, worker_host, reason}}
    end
  end

  defp parse_untracked_size(value) do
    case Integer.parse(String.trim(value)) do
      {size, ""} -> size
      _ -> :invalid
    end
  end

  @spec head(Path.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def head(workspace, worker_host \\ nil) when is_binary(workspace) do
    with {:ok, sha} <- git(workspace, worker_host, ["rev-parse", "HEAD"]) do
      sha = String.trim(sha)
      if Regex.match?(~r/^[a-f0-9]{40,64}$/, sha), do: {:ok, sha}, else: {:error, :invalid_repository_head}
    end
  end

  @spec changed_paths(Path.t(), String.t(), String.t() | nil) :: {:ok, [String.t()]} | {:error, term()}
  def changed_paths(workspace, base_sha, worker_host \\ nil) do
    commands = [
      committed: changed_path_args(["#{base_sha}..HEAD"]),
      unstaged: changed_path_args([]),
      staged: changed_path_args(["--cached"]),
      untracked: untracked_args()
    ]

    with {:ok, captured} <-
           parallel_git(
             commands,
             &git(workspace, worker_host, &1),
             @command_timeout_ms
           ),
         :ok <- bounded_changed_paths(captured) do
      paths =
        captured
        |> Map.values()
        |> Enum.flat_map(&String.split(&1, <<0>>, trim: true))
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, paths}
    end
  end

  defp changed_path_args(extra) do
    ["diff", "--name-only", "--no-renames", "-z"] ++ extra ++ ["--", "."] ++ exclusions()
  end

  defp bounded_changed_paths(captured) do
    Enum.reduce_while(captured, :ok, fn {label, value}, :ok ->
      case bounded(value, "changed paths #{label}") do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp status_args do
    ["status", "--porcelain=v1", "--untracked-files=all", "--", "."] ++ exclusions()
  end

  defp diff_args(extra) do
    ["diff", "--binary", "--no-ext-diff"] ++ extra ++ ["--", "."] ++ exclusions()
  end

  defp untracked_args do
    ["ls-files", "--others", "--exclude-standard", "-z", "--", "."] ++ exclusions()
  end

  defp exclusions do
    Enum.map(@engine_artifacts, &(":(exclude)" <> &1))
  end

  defp git(workspace, nil, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, args, status, output}}
    end
  end

  defp git(workspace, worker_host, args) when is_binary(worker_host) do
    command =
      ["git", "-C", shell_escape(workspace) | Enum.map(args, &shell_escape/1)]
      |> Enum.join(" ")

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {:git_failed, worker_host, args, status, output}}
      {:error, reason} -> {:error, {:git_failed, worker_host, args, reason}}
    end
  end

  defp bounded(value, _label) when byte_size(value) <= @max_snapshot_bytes, do: :ok
  defp bounded(_value, label), do: {:error, {:repository_snapshot_too_large, label, @max_snapshot_bytes}}

  defp sha256(iodata) do
    iodata
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
