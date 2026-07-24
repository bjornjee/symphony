defmodule SymphonyElixir.RepositoryFingerprint do
  @moduledoc """
  Captures the bounded repository identity and worktree state used by preactivation.
  """

  alias SymphonyElixir.SSH

  @max_snapshot_bytes 4_194_304
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
          unstaged_digest: String.t()
        }

  @spec capture(Path.t(), String.t() | nil) :: {:ok, snapshot()} | {:error, term()}
  def capture(workspace, worker_host \\ nil) when is_binary(workspace) do
    capture(workspace, worker_host, [])
  end

  @spec capture(Path.t(), String.t() | nil, keyword()) :: {:ok, snapshot()} | {:error, term()}
  def capture(workspace, worker_host, opts) when is_binary(workspace) and is_list(opts) do
    runner = Keyword.get(opts, :git_runner, &git(workspace, worker_host, &1))

    commands = [
      origin: ["config", "--get", "remote.origin.url"],
      base_sha: ["rev-parse", "HEAD"],
      status: status_args(),
      unstaged: diff_args([]),
      staged: diff_args(["--cached"])
    ]

    with {:ok, captured} <- parallel_git(commands, runner),
         origin <- captured.origin,
         base_sha <- captured.base_sha,
         status <- captured.status,
         unstaged <- captured.unstaged,
         staged <- captured.staged,
         :ok <- bounded(status, "status"),
         :ok <- bounded(unstaged, "unstaged diff"),
         :ok <- bounded(staged, "staged diff") do
      origin = String.trim(origin)
      base_sha = String.trim(base_sha)

      if origin == "" or not Regex.match?(~r/^[a-f0-9]{40,64}$/, base_sha) do
        {:error, :invalid_repository_identity}
      else
        digest = sha256([base_sha, <<0>>, status, <<0>>, unstaged, <<0>>, staged])

        {:ok,
         %{
           origin: origin,
           base_sha: base_sha,
           digest: digest,
           clean: String.trim(status) == "" and staged == "" and unstaged == "",
           status_digest: sha256(status),
           staged_digest: sha256(staged),
           unstaged_digest: sha256(unstaged)
         }}
      end
    end
  end

  defp parallel_git(commands, runner) do
    commands
    |> Task.async_stream(
      fn {key, args} -> {key, runner.(args)} end,
      max_concurrency: length(commands),
      ordered: true,
      timeout: 120_000,
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

  @spec head(Path.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def head(workspace, worker_host \\ nil) when is_binary(workspace) do
    with {:ok, sha} <- git(workspace, worker_host, ["rev-parse", "HEAD"]) do
      sha = String.trim(sha)
      if Regex.match?(~r/^[a-f0-9]{40,64}$/, sha), do: {:ok, sha}, else: {:error, :invalid_repository_head}
    end
  end

  @spec changed_paths(Path.t(), String.t(), String.t() | nil) :: {:ok, [String.t()]} | {:error, term()}
  def changed_paths(workspace, base_sha, worker_host \\ nil) do
    with {:ok, committed} <- git(workspace, worker_host, ["diff", "--name-only", "#{base_sha}..HEAD", "--", "."] ++ exclusions()),
         {:ok, status} <- git(workspace, worker_host, status_args()) do
      status_paths =
        status
        |> String.split("\n", trim: true)
        |> Enum.map(fn line -> line |> String.slice(3..-1//1) |> String.split(" -> ") |> List.last() end)

      {:ok, (String.split(committed, "\n", trim: true) ++ status_paths) |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp status_args do
    ["status", "--porcelain=v1", "--untracked-files=all", "--", "."] ++ exclusions()
  end

  defp diff_args(extra) do
    ["diff", "--binary", "--no-ext-diff"] ++ extra ++ ["--", "."] ++ exclusions()
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
