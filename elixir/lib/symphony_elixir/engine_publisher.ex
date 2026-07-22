defmodule SymphonyElixir.EnginePublisher do
  @moduledoc "Engine-owned, fail-closed task-branch and pull-request publication."

  alias SymphonyElixir.{RepositoryFingerprint, SSH}

  @conventional ~r/^(feat|fix|refactor|docs|test|chore|perf|ci): [^\r\n]+$/
  @self_attribution ~r/(generated with|co-authored-by:.*(?:codex|openai|chatgpt)|written by (?:codex|chatgpt))/i

  @spec publish(Path.t(), map(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def publish(workspace, plan, title, body, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    runner = Keyword.get(opts, :command_runner, &run/4)

    with :ok <- validate_content(plan, title, body),
         {:ok, state} <- RepositoryFingerprint.capture(workspace, worker_host),
         true <- state.clean || {:error, :publication_requires_clean_tree},
         {:ok, identity} <- repository_identity(workspace, plan, runner, worker_host),
         :ok <- validate_commits(workspace, identity.base_sha, runner, worker_host),
         {:ok, _output} <- git(runner, workspace, worker_host, ["push", "origin", identity.branch]),
         {:ok, pull_request} <- upsert_pull_request(runner, workspace, worker_host, identity, title, body),
         :ok <- validate_pull_request_repository(pull_request.url, identity.repository),
         true <-
           pull_request.head_sha == state.base_sha ||
             {:error, {:published_head_mismatch, pull_request.head_sha, state.base_sha}},
         true <- pull_request.head_branch == identity.branch || {:error, :published_branch_mismatch},
         true <- pull_request.base_branch == identity.base_branch || {:error, :published_base_mismatch} do
      {:ok,
       %{
         "url" => pull_request.url,
         "head_sha" => pull_request.head_sha,
         "head_branch" => pull_request.head_branch,
         "base_branch" => pull_request.base_branch,
         "origin" => identity.origin
       }}
    end
  end

  defp validate_content(plan, title, body) do
    commands = plan_proofs(plan) |> Enum.map(& &1["command"])
    sections = if is_binary(body), do: body_sections(body), else: %{}

    with :ok <- validate_title(title),
         :ok <- validate_body(body, sections),
         :ok <- reject_self_attribution(title, body) do
      validate_test_plan(commands, sections["Test plan"])
    end
  end

  defp validate_title(title) do
    if is_binary(title) and byte_size(title) <= 70 and Regex.match?(@conventional, title),
      do: :ok,
      else: {:error, :invalid_pull_request_title}
  end

  defp validate_body(body, sections) do
    if is_binary(body) and valid_body_sections?(sections),
      do: :ok,
      else: {:error, :invalid_pull_request_body}
  end

  defp reject_self_attribution(title, body) do
    if Regex.match?(@self_attribution, title <> "\n" <> body),
      do: {:error, :pull_request_self_attribution},
      else: :ok
  end

  defp validate_test_plan(commands, test_plan) do
    if Enum.all?(commands, &String.contains?(test_plan, &1)),
      do: :ok,
      else: {:error, :pull_request_test_plan_mismatch}
  end

  defp body_sections(body) do
    ~r/^## (Why|Summary|Test plan)\s*\n(.*?)(?=^## |\z)/ms
    |> Regex.scan(body, capture: :all_but_first)
    |> Map.new(fn [heading, content] -> {heading, String.trim(content)} end)
  end

  defp valid_body_sections?(sections) do
    Map.keys(sections) |> Enum.sort() == Enum.sort(["Why", "Summary", "Test plan"]) and
      Enum.all?(sections, fn {_heading, content} -> content != "" end)
  end

  defp repository_identity(workspace, plan, runner, worker_host) do
    with {:ok, origin} <- git(runner, workspace, worker_host, ["remote", "get-url", "origin"]),
         origin <- String.trim(origin),
         true <- origin == plan_origin(plan) || {:error, :publication_origin_drift},
         {:ok, branch} <- git(runner, workspace, worker_host, ["branch", "--show-current"]),
         branch <- String.trim(branch),
         true <- String.starts_with?(branch, plan["workflow"] <> "/") || {:error, :invalid_task_branch},
         {:ok, _output} <- git(runner, workspace, worker_host, ["merge-base", "--is-ancestor", plan_base(plan), "HEAD"]),
         {:ok, base_ref} <- git(runner, workspace, worker_host, ["symbolic-ref", "refs/remotes/origin/HEAD"]),
         {:ok, repository} <- github_repository(origin) do
      {:ok,
       %{
         origin: origin,
         branch: branch,
         base_sha: plan_base(plan),
         base_branch: base_ref |> String.trim() |> String.replace_prefix("refs/remotes/origin/", ""),
         repository: repository
       }}
    end
  end

  defp validate_commits(workspace, base_sha, runner, worker_host) do
    with {:ok, output} <- git(runner, workspace, worker_host, ["log", "--format=%s", "#{base_sha}..HEAD"]) do
      subjects = String.split(output, "\n", trim: true)

      cond do
        subjects == [] -> {:error, :publication_commit_required}
        Enum.any?(subjects, &(not Regex.match?(@conventional, &1))) -> {:error, :nonconventional_commit}
        true -> :ok
      end
    end
  end

  defp upsert_pull_request(runner, workspace, worker_host, identity, title, body) do
    args = ["pr", "list", "--repo", identity.repository, "--head", identity.branch, "--state", "open", "--limit", "2", "--json", "url,headRefOid,headRefName,baseRefName"]

    with {:ok, output} <- command(runner, workspace, worker_host, "gh", args),
         {:ok, pulls} when is_list(pulls) <- Jason.decode(output),
         {:ok, url} <- ensure_one_pull_request(pulls, runner, workspace, worker_host, identity, title, body),
         {:ok, readback} <- command(runner, workspace, worker_host, "gh", ["pr", "view", url, "--repo", identity.repository, "--json", "url,headRefOid,headRefName,baseRefName"]),
         {:ok, payload} <- Jason.decode(readback) do
      decode_pull_request(payload)
    else
      {:ok, pulls} when is_list(pulls) -> {:error, {:multiple_pull_requests_for_branch, length(pulls)}}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_github_response, other}}
    end
  end

  defp ensure_one_pull_request([], runner, workspace, worker_host, identity, title, body) do
    with {:ok, output} <-
           command(runner, workspace, worker_host, "gh", [
             "pr",
             "create",
             "--repo",
             identity.repository,
             "--head",
             identity.branch,
             "--base",
             identity.base_branch,
             "--title",
             title,
             "--body",
             body
           ]) do
      url = String.trim(output)
      if String.starts_with?(url, "https://github.com/"), do: {:ok, url}, else: {:error, :invalid_created_pull_request_url}
    end
  end

  defp ensure_one_pull_request([%{"url" => url}], runner, workspace, worker_host, identity, title, body) do
    with {:ok, _output} <-
           command(runner, workspace, worker_host, "gh", ["pr", "edit", url, "--repo", identity.repository, "--title", title, "--body", body]) do
      {:ok, url}
    end
  end

  defp ensure_one_pull_request(pulls, _runner, _workspace, _worker_host, _identity, _title, _body),
    do: {:error, {:multiple_pull_requests_for_branch, length(pulls)}}

  defp decode_pull_request(%{"url" => url, "headRefOid" => sha, "headRefName" => head, "baseRefName" => base})
       when is_binary(url) and is_binary(sha) and is_binary(head) and is_binary(base) do
    {:ok, %{url: url, head_sha: sha, head_branch: head, base_branch: base}}
  end

  defp decode_pull_request(payload), do: {:error, {:invalid_pull_request_readback, payload}}

  defp validate_pull_request_repository(url, expected) do
    with %URI{scheme: "https", host: "github.com", path: path} <- URI.parse(url),
         [owner, repo, "pull", number] <- String.split(path || "", "/", trim: true) do
      validate_pull_request_parts(owner, repo, number, expected)
    else
      _ -> {:error, :invalid_published_pull_request_url}
    end
  end

  defp validate_pull_request_parts(owner, repo, number, expected) do
    if "#{owner}/#{repo}" == expected and Regex.match?(~r/^[1-9][0-9]*$/, number),
      do: :ok,
      else: {:error, :published_repository_mismatch}
  end

  defp github_repository(origin) do
    case Regex.run(~r/^(?:git@)?github\.com:([^\/]+)\/(.+?)(?:\.git)?$/, origin, capture: :all_but_first) do
      [owner, repo] -> {:ok, "#{owner}/#{String.trim_trailing(repo, ".git")}"}
      _ -> github_https_repository(origin)
    end
  end

  defp github_https_repository(origin) do
    case URI.parse(origin) do
      %URI{host: "github.com", path: path} ->
        case String.split(path || "", "/", trim: true) do
          [owner, repo] -> {:ok, "#{owner}/#{String.trim_trailing(repo, ".git")}"}
          _ -> {:error, :unsupported_repository_origin}
        end

      _ ->
        {:error, :unsupported_repository_origin}
    end
  end

  defp git(runner, workspace, worker_host, args), do: command(runner, workspace, worker_host, "git", ["-C", workspace | args])

  defp command(runner, workspace, worker_host, executable, args) do
    case runner.(workspace, worker_host, executable, args) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {:command_failed, executable, args, status, output}}
      {:error, reason} -> {:error, {:command_failed, executable, args, reason}}
    end
  end

  defp run(workspace, nil, executable, args) do
    case System.find_executable(executable) do
      nil -> {:error, {:executable_unavailable, executable}}
      path -> {:ok, System.cmd(path, args, cd: workspace, stderr_to_stdout: true)}
    end
  end

  defp run(_workspace, worker_host, executable, args) do
    command = Enum.map_join([executable | args], " ", &shell_escape/1)
    SSH.run(worker_host, command, stderr_to_stdout: true)
  end

  defp plan_proofs(%{"candidate" => %{"proofs" => proofs}}), do: proofs
  defp plan_proofs(%{"proofs" => proofs}), do: proofs
  defp plan_origin(%{"candidate" => %{"repository" => %{"origin" => origin}}}), do: origin
  defp plan_origin(%{"repository" => %{"origin" => origin}}), do: origin
  defp plan_base(%{"candidate" => %{"repository" => %{"base_sha" => sha}}}), do: sha
  defp plan_base(%{"repository" => %{"base_sha" => sha}}), do: sha
  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
