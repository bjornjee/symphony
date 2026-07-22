defmodule SymphonyElixir.RepositoryReviewSnapshot do
  @moduledoc "Bounded base-to-head repository evidence for isolated implementation review."

  alias SymphonyElixir.{RepositoryFingerprint, SSH}

  @max_diff_bytes 4_194_304

  @spec capture(Path.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def capture(workspace, base_sha, worker_host \\ nil) do
    with {:ok, diff} <- git(workspace, worker_host, ["diff", "--binary", "--no-ext-diff", "#{base_sha}..HEAD", "--", "."]),
         true <- byte_size(diff) <= @max_diff_bytes || {:error, :implementation_review_diff_too_large},
         {:ok, changed_paths} <- RepositoryFingerprint.changed_paths(workspace, base_sha, worker_host),
         {:ok, repository} <- RepositoryFingerprint.capture(workspace, worker_host) do
      {:ok, %{diff: diff, changed_paths: changed_paths, repository: repository}}
    end
  end

  defp git(workspace, nil, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, args, status, output}}
    end
  end

  defp git(workspace, worker_host, args) do
    command = Enum.map_join(["git", "-C", workspace | args], " ", &shell_escape/1)

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {:git_failed, worker_host, args, status, output}}
      {:error, reason} -> {:error, {:git_failed, worker_host, args, reason}}
    end
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
