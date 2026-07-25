defmodule SymphonyElixir.TaskBranch do
  @moduledoc """
  Creates or resumes the single task branch after goal activation.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.SSH

  @spec ensure(Path.t(), Issue.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def ensure(workspace, %Issue{} = issue, workflow, base_sha, worker_host \\ nil)
      when is_binary(workspace) and is_binary(workflow) and is_binary(base_sha) do
    branch = branch_name(issue, workflow)

    with {:ok, current} <- git(workspace, worker_host, ["branch", "--show-current"]),
         {:ok, head} <- git(workspace, worker_host, ["rev-parse", "HEAD"]) do
      ensure_branch(workspace, worker_host, String.trim(current), String.trim(head), branch, base_sha)
    end
  end

  @spec validate(Path.t(), Issue.t(), String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def validate(workspace, %Issue{} = issue, workflow, base_sha, worker_host \\ nil) do
    expected = branch_name(issue, workflow)

    with {:ok, current} <- git(workspace, worker_host, ["branch", "--show-current"]),
         true <- String.trim(current) == expected || {:error, {:unexpected_task_branch, String.trim(current)}},
         {:ok, ^expected} <- validate_branch_base(workspace, worker_host, expected, base_sha, "HEAD") do
      :ok
    end
  end

  defp ensure_branch(workspace, worker_host, branch, _head, branch, base_sha) do
    validate_branch_base(workspace, worker_host, branch, base_sha, "HEAD")
  end

  defp ensure_branch(workspace, worker_host, _current, base_sha, branch, base_sha) do
    case git_status(workspace, worker_host, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"]) do
      0 ->
        with {:ok, ^branch} <-
               validate_branch_base(workspace, worker_host, branch, base_sha, "refs/heads/#{branch}"),
             {:ok, _output} <- git(workspace, worker_host, ["switch", branch]) do
          {:ok, branch}
        end

      1 ->
        case git(workspace, worker_host, ["switch", "-c", branch, base_sha]) do
          {:ok, _output} -> {:ok, branch}
          {:error, _reason} = error -> error
        end

      status ->
        {:error, {:task_branch_lookup_failed, branch, status}}
    end
  end

  defp ensure_branch(_workspace, _worker_host, current, _head, _branch, _base_sha) do
    {:error, {:unexpected_task_branch, current}}
  end

  defp validate_branch_base(workspace, worker_host, branch, base_sha, target) do
    case git_status(workspace, worker_host, ["merge-base", "--is-ancestor", base_sha, target]) do
      0 -> {:ok, branch}
      1 -> {:error, {:task_branch_base_mismatch, branch, base_sha, 1}}
      status -> {:error, {:task_branch_base_validation_failed, branch, base_sha, status}}
    end
  end

  defp branch_name(%Issue{identifier: identifier, title: title}, workflow) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 48)
      |> String.trim("-")

    "#{workflow}/#{String.downcase(identifier)}-#{slug}"
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

  defp git_status(workspace, nil, args) do
    {_output, status} = System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true)
    status
  end

  defp git_status(workspace, worker_host, args) when is_binary(worker_host) do
    command =
      ["git", "-C", shell_escape(workspace) | Enum.map(args, &shell_escape/1)]
      |> Enum.join(" ")

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {_output, status}} -> status
      {:error, _reason} -> 255
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
