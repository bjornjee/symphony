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
    ".symphony/plan-candidate-*.json",
    ".symphony/plan-review-*.json",
    ".symphony/execution-plan.json"
  ]

  @type snapshot :: %{origin: String.t(), base_sha: String.t(), digest: String.t()}

  @spec capture(Path.t(), String.t() | nil) :: {:ok, snapshot()} | {:error, term()}
  def capture(workspace, worker_host \\ nil) when is_binary(workspace) do
    with {:ok, origin} <- git(workspace, worker_host, ["config", "--get", "remote.origin.url"]),
         {:ok, base_sha} <- git(workspace, worker_host, ["rev-parse", "HEAD"]),
         {:ok, status} <- git(workspace, worker_host, status_args()),
         {:ok, unstaged} <- git(workspace, worker_host, diff_args([])),
         {:ok, staged} <- git(workspace, worker_host, diff_args(["--cached"])),
         :ok <- bounded(status, "status"),
         :ok <- bounded(unstaged, "unstaged diff"),
         :ok <- bounded(staged, "staged diff") do
      origin = String.trim(origin)
      base_sha = String.trim(base_sha)

      if origin == "" or not Regex.match?(~r/^[a-f0-9]{40,64}$/, base_sha) do
        {:error, :invalid_repository_identity}
      else
        digest = sha256([base_sha, <<0>>, status, <<0>>, unstaged, <<0>>, staged])
        {:ok, %{origin: origin, base_sha: base_sha, digest: digest}}
      end
    end
  end

  @spec head(Path.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def head(workspace, worker_host \\ nil) when is_binary(workspace) do
    with {:ok, sha} <- git(workspace, worker_host, ["rev-parse", "HEAD"]) do
      sha = String.trim(sha)
      if Regex.match?(~r/^[a-f0-9]{40,64}$/, sha), do: {:ok, sha}, else: {:error, :invalid_repository_head}
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
