defmodule SymphonyElixir.CompletionEvidence do
  @moduledoc """
  Validates agent-authored handoff evidence against engine-observed command proof.
  """

  alias SymphonyElixir.Linear.{Issue, TaskContract}
  alias SymphonyElixir.SSH

  @schema_version 1
  @artifact_path Path.join(".symphony", "completion-evidence.json")
  @max_artifact_bytes 131_072
  @max_observed_proofs 256

  @type observed_proofs :: %{optional(String.t()) => %{required(:exit_code) => integer()}}

  @spec path(Path.t()) :: Path.t()
  def path(workspace) when is_binary(workspace), do: Path.join(workspace, @artifact_path)

  @spec validate(Path.t(), Issue.t(), TaskContract.t(), observed_proofs(), keyword()) ::
          {:ok, %{pull_request_url: String.t()}} | {:error, term()}
  def validate(workspace, %Issue{} = issue, %TaskContract{} = contract, observed_proofs, opts \\ [])
      when is_binary(workspace) and is_map(observed_proofs) do
    with :ok <- validate_observed_proof_limit(observed_proofs),
         {:ok, payload} <- read(workspace, Keyword.get(opts, :worker_host)),
         {:ok, evidence} <- decode(payload),
         :ok <- validate_envelope(evidence, issue, contract),
         :ok <- validate_criteria(evidence, contract, observed_proofs),
         {:ok, pull_request_url} <- validate_pull_request(evidence, workspace, opts) do
      {:ok, %{pull_request_url: pull_request_url}}
    end
  end

  defp validate_observed_proof_limit(proofs) when map_size(proofs) <= @max_observed_proofs, do: :ok

  defp validate_observed_proof_limit(_proofs) do
    {:error, {:observed_proof_limit_exceeded, @max_observed_proofs}}
  end

  defp read(workspace, nil) do
    artifact_path = path(workspace)

    case File.stat(artifact_path) do
      {:ok, %{size: size}} when size > @max_artifact_bytes ->
        {:error, {:completion_evidence_too_large, @max_artifact_bytes}}

      {:ok, _stat} ->
        case File.read(artifact_path) do
          {:ok, payload} -> {:ok, payload}
          {:error, reason} -> {:error, {:completion_evidence_read_failed, reason}}
        end

      {:error, :enoent} ->
        {:error, :completion_evidence_missing}

      {:error, reason} ->
        {:error, {:completion_evidence_read_failed, reason}}
    end
  end

  defp read(workspace, worker_host) when is_binary(worker_host) do
    command =
      [
        "artifact=#{shell_escape(path(workspace))}",
        "[ -f \"$artifact\" ] || exit 44",
        "[ \"$(wc -c < \"$artifact\")\" -le #{@max_artifact_bytes} ] || exit 45",
        "cat \"$artifact\""
      ]
      |> Enum.join("\n")

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {payload, 0}} -> {:ok, payload}
      {:ok, {_output, 44}} -> {:error, :completion_evidence_missing}
      {:ok, {_output, 45}} -> {:error, {:completion_evidence_too_large, @max_artifact_bytes}}
      {:ok, {output, status}} -> {:error, {:completion_evidence_read_failed, worker_host, status, output}}
      {:error, reason} -> {:error, {:completion_evidence_read_failed, worker_host, reason}}
    end
  end

  defp decode(payload) do
    case Jason.decode(payload) do
      {:ok, evidence} when is_map(evidence) -> {:ok, evidence}
      {:ok, _other} -> {:error, {:malformed_completion_evidence, :not_an_object}}
      {:error, reason} -> {:error, {:malformed_completion_evidence, reason}}
    end
  end

  defp validate_envelope(evidence, issue, contract) do
    cond do
      evidence["schema_version"] != @schema_version ->
        {:error, {:unsupported_completion_evidence_version, evidence["schema_version"]}}

      evidence["issue_id"] != issue.id ->
        {:error, {:completion_evidence_issue_mismatch, evidence["issue_id"], issue.id}}

      evidence["issue_identifier"] != issue.identifier ->
        {:error, {:completion_evidence_identifier_mismatch, evidence["issue_identifier"], issue.identifier}}

      evidence["plan_digest"] != contract.digest ->
        {:error, {:completion_evidence_plan_digest_mismatch, evidence["plan_digest"], contract.digest}}

      not is_list(evidence["criteria"]) ->
        {:error, :malformed_criterion_evidence}

      true ->
        :ok
    end
  end

  defp validate_criteria(evidence, contract, observed_proofs) do
    criteria = evidence["criteria"]
    expected_ids = Enum.map(contract.acceptance_criteria, & &1.id)
    actual_ids = Enum.map(criteria, &criterion_id/1)
    duplicate_ids = duplicates(actual_ids)
    unmatched_ids = (actual_ids -- expected_ids) |> Enum.uniq() |> Enum.sort()
    missing_ids = (expected_ids -- actual_ids) |> Enum.sort()

    cond do
      Enum.any?(actual_ids, &is_nil/1) ->
        {:error, :malformed_criterion_evidence}

      duplicate_ids != [] ->
        {:error, {:duplicate_criterion_evidence, duplicate_ids}}

      unmatched_ids != [] ->
        {:error, {:unmatched_criterion_evidence, unmatched_ids}}

      missing_ids != [] ->
        {:error, {:missing_criterion_evidence, missing_ids}}

      true ->
        validate_proofs(criteria, observed_proofs)
    end
  end

  defp criterion_id(%{"criterion_id" => criterion_id}) when is_binary(criterion_id), do: criterion_id
  defp criterion_id(_criterion), do: nil

  defp duplicates(ids) do
    ids
    |> Enum.frequencies()
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp validate_proofs(criteria, observed_proofs) do
    Enum.reduce_while(criteria, :ok, fn criterion, :ok ->
      case validate_proof(criterion, observed_proofs) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_proof(
         %{
           "criterion_id" => criterion_id,
           "proof" => %{"kind" => "run_audit_command", "event_id" => event_id}
         },
         observed_proofs
       )
       when is_binary(event_id) do
    validate_observed_proof(Map.get(observed_proofs, event_id), criterion_id, event_id)
  end

  defp validate_proof(%{"criterion_id" => criterion_id}, _observed_proofs) do
    {:error, {:malformed_criterion_proof, criterion_id}}
  end

  defp validate_observed_proof(%{exit_code: 0}, _criterion_id, _event_id), do: :ok

  defp validate_observed_proof(%{exit_code: exit_code}, criterion_id, event_id) do
    {:error, {:failed_criterion_proof, criterion_id, event_id, exit_code}}
  end

  defp validate_observed_proof(nil, criterion_id, event_id) do
    {:error, {:unobserved_criterion_proof, criterion_id, event_id}}
  end

  defp validate_observed_proof(_proof, _criterion_id, event_id) do
    {:error, {:malformed_observed_proof, event_id}}
  end

  defp validate_pull_request(evidence, workspace, opts) do
    case evidence["pull_request_url"] do
      url when is_binary(url) and url != "" ->
        with {:ok, actual_repository} <- pull_request_repository(url),
             {:ok, origin_url} <- origin_url(workspace, opts),
             {:ok, expected_repository} <- origin_repository(origin_url),
             :ok <- compare_repositories(expected_repository, actual_repository),
             :ok <- verify_pull_request(url, workspace, opts) do
          {:ok, url}
        end

      _other ->
        {:error, :missing_pull_request_url}
    end
  end

  defp pull_request_repository(url) do
    uri = URI.parse(url)

    case {uri.scheme, uri.host, uri.port, uri.userinfo, uri.query, uri.fragment, split_path(uri.path)} do
      {"https", "github.com", 443, nil, nil, nil, [owner, repo, "pull", number]}
      when owner != "" and repo != "" ->
        case Integer.parse(number) do
          {pull_number, ""} when pull_number > 0 -> {:ok, normalize_repository(owner, repo)}
          _other -> {:error, {:invalid_pull_request_url, url}}
        end

      _other ->
        {:error, {:invalid_pull_request_url, url}}
    end
  end

  defp origin_url(workspace, opts) do
    case Keyword.get(opts, :origin_url) do
      origin_url when is_binary(origin_url) ->
        {:ok, origin_url}

      _other ->
        worker_host = Keyword.get(opts, :worker_host)

        case repository_origin(workspace, worker_host) do
          {:ok, output} -> {:ok, String.trim(output)}
          {:error, reason} -> {:error, {:repository_origin_unavailable, reason}}
        end
    end
  end

  defp origin_repository(url) when is_binary(url) do
    case Regex.run(~r/^(?:git@)?github\.com:([^\/]+)\/(.+?)(?:\.git)?$/, url, capture: :all_but_first) do
      [owner, repo] ->
        {:ok, normalize_repository(owner, repo)}

      _other ->
        uri = URI.parse(url)

        case {uri.host, split_path(uri.path)} do
          {"github.com", [owner, repo]} -> {:ok, normalize_repository(owner, String.trim_trailing(repo, ".git"))}
          _other -> {:error, {:unsupported_repository_origin, url}}
        end
    end
  end

  defp compare_repositories(repository, repository), do: :ok

  defp compare_repositories(expected, actual) do
    {:error, {:pull_request_repository_mismatch, %{expected: expected, actual: actual}}}
  end

  defp verify_pull_request(url, workspace, opts) do
    verifier = Keyword.get(opts, :pull_request_verifier, &verify_pull_request_with_gh/3)

    case verifier.(url, workspace, Keyword.get(opts, :worker_host)) do
      {:ok, ^url} -> :ok
      {:ok, other_url} -> {:error, {:pull_request_url_mismatch, %{expected: url, actual: other_url}}}
      {:error, reason} -> {:error, {:pull_request_unavailable, reason}}
      other -> {:error, {:pull_request_verification_failed, other}}
    end
  end

  defp verify_pull_request_with_gh(url, workspace, nil) do
    case System.find_executable("gh") do
      nil ->
        {:error, :github_cli_unavailable}

      executable ->
        case System.cmd(executable, ["pr", "view", url, "--json", "url", "--jq", ".url"],
               cd: workspace,
               stderr_to_stdout: true
             ) do
          {output, 0} -> {:ok, String.trim(output)}
          {output, status} -> {:error, {status, String.trim(output)}}
        end
    end
  end

  defp verify_pull_request_with_gh(url, _workspace, worker_host) when is_binary(worker_host) do
    command = "gh pr view #{shell_escape(url)} --json url --jq .url"

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {output, status}} -> {:error, {worker_host, status, String.trim(output)}}
      {:error, reason} -> {:error, {worker_host, reason}}
    end
  end

  defp normalize_repository(owner, repo), do: String.downcase("#{owner}/#{repo}")
  defp split_path(nil), do: []
  defp split_path(path), do: String.split(path, "/", trim: true)

  defp repository_origin(workspace, nil) do
    case System.cmd("git", ["-C", workspace, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, output}}
    end
  end

  defp repository_origin(workspace, worker_host) when is_binary(worker_host) do
    command = "git -C #{shell_escape(workspace)} remote get-url origin"

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {worker_host, status, output}}
      {:error, reason} -> {:error, {worker_host, reason}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
