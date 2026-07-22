defmodule SymphonyElixir.CompletionEvidence do
  @moduledoc """
  Validates agent-authored handoff evidence against engine-observed command proof.
  """

  alias SymphonyElixir.Linear.{Issue, TaskContract}
  alias SymphonyElixir.PlanningArtifact
  alias SymphonyElixir.RepositoryFingerprint
  alias SymphonyElixir.SSH
  alias SymphonyElixir.WorkspaceArtifact

  @schema_version 2
  @artifact_path Path.join(".symphony", "completion-evidence.json")
  @max_artifact_bytes 131_072
  @max_observed_proofs 256

  @type observed_proofs :: %{optional(String.t()) => %{required(:exit_code) => integer()}}

  @spec path(Path.t()) :: Path.t()
  def path(workspace) when is_binary(workspace), do: Path.join(workspace, @artifact_path)

  @spec validate(Path.t(), Issue.t(), TaskContract.t(), observed_proofs(), keyword()) ::
          {:ok,
           %{
             artifact_digest: String.t(),
             criteria: [%{criterion_id: String.t(), proof_event_id: String.t()}],
             pull_request_url: String.t()
           }}
          | {:error, term()}
  def validate(workspace, %Issue{} = issue, %TaskContract{} = contract, observed_proofs, opts \\ [])
      when is_binary(workspace) and is_map(observed_proofs) do
    with :ok <- validate_observed_proof_limit(observed_proofs),
         {:ok, payload} <- read(workspace, Keyword.get(opts, :worker_host)),
         {:ok, evidence} <- decode(payload),
         {:ok, execution_plan} <- execution_plan(workspace, opts),
         :ok <- validate_envelope(evidence, issue, contract, execution_plan),
         {:ok, repository_head_sha} <- repository_head(workspace, opts),
         :ok <- validate_criteria(evidence, contract, observed_proofs, repository_head_sha),
         :ok <- validate_workflow_proof(evidence, execution_plan, observed_proofs, repository_head_sha),
         {:ok, pull_request} <- validate_pull_request(evidence, workspace, opts),
         :ok <- validate_repository_heads(evidence, repository_head_sha, pull_request.head_sha) do
      {:ok,
       %{
         artifact_digest: semantic_artifact_digest(evidence),
         criteria: criterion_summaries(evidence),
         pull_request_url: pull_request.url,
         repository_head_sha: repository_head_sha,
         execution_plan_digest: execution_plan["plan_digest"],
         workflow: execution_plan["workflow"],
         profile_digest: execution_plan["profile_digest"]
       }}
    end
  end

  defp validate_observed_proof_limit(proofs) when map_size(proofs) <= @max_observed_proofs, do: :ok

  defp validate_observed_proof_limit(_proofs) do
    {:error, {:observed_proof_limit_exceeded, @max_observed_proofs}}
  end

  defp read(workspace, nil) do
    case WorkspaceArtifact.read(path(workspace), @max_artifact_bytes) do
      {:ok, payload} ->
        {:ok, payload}

      :missing ->
        {:error, :completion_evidence_missing}

      {:error, {:artifact_too_large, _max_bytes}} ->
        {:error, {:completion_evidence_too_large, @max_artifact_bytes}}

      {:error, reason} ->
        {:error, {:completion_evidence_read_failed, reason}}
    end
  end

  defp read(workspace, worker_host) when is_binary(worker_host) do
    case WorkspaceArtifact.read(path(workspace), @max_artifact_bytes, worker_host) do
      {:ok, payload} ->
        {:ok, payload}

      :missing ->
        {:error, :completion_evidence_missing}

      {:error, {:artifact_too_large, _max_bytes}} ->
        {:error, {:completion_evidence_too_large, @max_artifact_bytes}}

      {:error, {:remote_command_failed, status, output}} ->
        {:error, {:completion_evidence_read_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, {:completion_evidence_read_failed, worker_host, reason}}
    end
  end

  defp decode(payload) do
    case Jason.decode(payload) do
      {:ok, evidence} when is_map(evidence) -> {:ok, evidence}
      {:ok, _other} -> {:error, {:malformed_completion_evidence, :not_an_object}}
      {:error, reason} -> {:error, {:malformed_completion_evidence, reason}}
    end
  end

  defp validate_envelope(evidence, issue, contract, execution_plan) do
    with :ok <- validate_evidence_identity(evidence, issue, contract),
         :ok <- validate_evidence_plan(evidence, execution_plan) do
      if is_list(evidence["criteria"]), do: :ok, else: {:error, :malformed_criterion_evidence}
    end
  end

  defp validate_evidence_identity(evidence, issue, contract) do
    cond do
      evidence["schema_version"] != @schema_version ->
        {:error, {:unsupported_completion_evidence_version, evidence["schema_version"]}}

      evidence["issue_id"] != issue.id ->
        {:error, {:completion_evidence_issue_mismatch, evidence["issue_id"], issue.id}}

      evidence["issue_identifier"] != issue.identifier ->
        {:error, {:completion_evidence_identifier_mismatch, evidence["issue_identifier"], issue.identifier}}

      evidence["plan_digest"] != contract.digest ->
        {:error, {:completion_evidence_plan_digest_mismatch, evidence["plan_digest"], contract.digest}}

      true ->
        :ok
    end
  end

  defp validate_evidence_plan(evidence, execution_plan) do
    cond do
      evidence["execution_plan_digest"] != execution_plan["plan_digest"] ->
        {:error, {:completion_evidence_execution_plan_mismatch, evidence["execution_plan_digest"], execution_plan["plan_digest"]}}

      evidence["workflow"] != execution_plan["workflow"] ->
        {:error, {:completion_evidence_workflow_mismatch, evidence["workflow"], execution_plan["workflow"]}}

      evidence["profile_digest"] != execution_plan["profile_digest"] ->
        {:error, {:completion_evidence_profile_mismatch, evidence["profile_digest"], execution_plan["profile_digest"]}}

      true ->
        :ok
    end
  end

  defp validate_criteria(evidence, contract, observed_proofs, repository_head_sha) do
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
        validate_proofs(criteria, observed_proofs, repository_head_sha)
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

  defp validate_proofs(criteria, observed_proofs, repository_head_sha) do
    Enum.reduce_while(criteria, :ok, fn criterion, :ok ->
      case validate_proof(criterion, observed_proofs, repository_head_sha) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp criterion_summaries(evidence) do
    Enum.map(evidence["criteria"], fn criterion ->
      %{
        criterion_id: criterion["criterion_id"],
        proof_event_id: get_in(criterion, ["proof", "event_id"])
      }
    end)
  end

  defp semantic_artifact_digest(evidence) do
    criterion_ids = Enum.map(evidence["criteria"], & &1["criterion_id"])

    :crypto.hash(
      :sha256,
      [
        "completion-evidence:v2",
        0,
        evidence["issue_id"],
        0,
        evidence["issue_identifier"],
        0,
        evidence["plan_digest"],
        0,
        evidence["execution_plan_digest"],
        0,
        evidence["workflow"],
        0,
        evidence["profile_digest"],
        0,
        evidence["repository_head_sha"],
        0,
        evidence["pr_head_sha"],
        0,
        Enum.intersperse(criterion_ids, <<0>>),
        0,
        evidence["pull_request_url"]
      ]
    )
    |> Base.encode16(case: :lower)
  end

  defp validate_proof(
         %{
           "criterion_id" => criterion_id,
           "proof" => %{"kind" => "run_audit_command", "event_id" => event_id}
         },
         observed_proofs,
         repository_head_sha
       )
       when is_binary(event_id) do
    validate_successful_fresh_proof(
      Map.get(observed_proofs, event_id),
      criterion_id,
      event_id,
      repository_head_sha
    )
  end

  defp validate_proof(%{"criterion_id" => criterion_id}, _observed_proofs, _repository_head_sha) do
    {:error, {:malformed_criterion_proof, criterion_id}}
  end

  defp validate_successful_fresh_proof(
         %{exit_code: 0, head_sha: repository_head_sha},
         _criterion_id,
         _event_id,
         repository_head_sha
       ),
       do: :ok

  defp validate_successful_fresh_proof(%{exit_code: 0, head_sha: head_sha}, criterion_id, event_id, expected_head) do
    {:error, {:stale_criterion_proof, criterion_id, event_id, head_sha, expected_head}}
  end

  defp validate_successful_fresh_proof(%{exit_code: exit_code}, criterion_id, event_id, _repository_head_sha) do
    {:error, {:failed_criterion_proof, criterion_id, event_id, exit_code}}
  end

  defp validate_successful_fresh_proof(nil, criterion_id, event_id, _repository_head_sha) do
    {:error, {:unobserved_criterion_proof, criterion_id, event_id}}
  end

  defp validate_successful_fresh_proof(_proof, _criterion_id, event_id, _repository_head_sha) do
    {:error, {:malformed_observed_proof, event_id}}
  end

  defp execution_plan(workspace, opts) do
    case Keyword.get(opts, :execution_plan) do
      plan when is_map(plan) ->
        {:ok, plan}

      _other ->
        case PlanningArtifact.read_execution_plan(workspace, Keyword.get(opts, :worker_host)) do
          {:ok, plan} -> {:ok, plan}
          :missing -> {:error, :execution_plan_missing}
          {:error, reason} -> {:error, {:execution_plan_invalid, reason}}
        end
    end
  end

  defp repository_head(workspace, opts) do
    case Keyword.get(opts, :repository_head_sha) do
      sha when is_binary(sha) -> {:ok, sha}
      _other -> RepositoryFingerprint.head(workspace, Keyword.get(opts, :worker_host))
    end
  end

  defp validate_workflow_proof(evidence, execution_plan, observed, repository_head_sha) do
    proof = evidence["workflow_proof"]

    case execution_plan["workflow"] do
      "fix" -> validate_fix_proof(proof, observed, repository_head_sha)
      "refactor" -> validate_refactor_proof(proof, observed, repository_head_sha)
      "feature" -> validate_feature_proof(proof, execution_plan, observed, repository_head_sha)
      "chore" -> validate_chore_proof(proof, observed, repository_head_sha)
      "pr" -> validate_final_proof(proof, "final_proof_event_id", observed, repository_head_sha)
      workflow -> {:error, {:unsupported_evidence_workflow, workflow}}
    end
  end

  defp validate_fix_proof(
         %{"red_event_id" => red_id, "green_event_id" => green_id},
         observed,
         repository_head_sha
       ) do
    with {:ok, red} <- observed_event(observed, red_id, "red_event_id"),
         true <- red.exit_code != 0 || {:error, :fix_red_did_not_fail},
         {:ok, green} <- successful_fresh_event(observed, green_id, "green_event_id", repository_head_sha) do
      ordered_events(red, green, :fix_red_not_before_green)
    end
  end

  defp validate_fix_proof(_proof, _observed, _head), do: {:error, :malformed_fix_workflow_proof}

  defp validate_refactor_proof(
         %{"baseline_event_id" => baseline_id, "final_proof_event_id" => final_id},
         observed,
         repository_head_sha
       ) do
    with {:ok, baseline} <- successful_event(observed, baseline_id, "baseline_event_id"),
         {:ok, final} <- successful_fresh_event(observed, final_id, "final_proof_event_id", repository_head_sha) do
      ordered_events(baseline, final, :refactor_baseline_not_before_final)
    end
  end

  defp validate_refactor_proof(_proof, _observed, _head),
    do: {:error, :malformed_refactor_workflow_proof}

  defp validate_feature_proof(proof, execution_plan, observed, repository_head_sha) when is_map(proof) do
    with :ok <- validate_final_proof(proof, "final_proof_event_id", observed, repository_head_sha) do
      validate_feature_red(proof, execution_plan, observed)
    end
  end

  defp validate_feature_proof(_proof, _execution_plan, _observed, _head),
    do: {:error, :malformed_feature_workflow_proof}

  defp validate_feature_red(proof, execution_plan, observed) do
    if feature_requires_red?(execution_plan),
      do: validate_declared_feature_red(proof["red_event_id"], observed),
      else: :ok
  end

  defp validate_declared_feature_red(red_id, observed) when is_binary(red_id) do
    with {:ok, red} <- observed_event(observed, red_id, "red_event_id"),
         true <- red.exit_code != 0 || {:error, :feature_red_did_not_fail},
         do: :ok
  end

  defp validate_declared_feature_red(_red_id, _observed), do: {:error, :feature_red_evidence_missing}

  defp validate_chore_proof(%{"validator_event_id" => event_id}, observed, repository_head_sha) do
    case successful_fresh_event(observed, event_id, "validator_event_id", repository_head_sha) do
      {:ok, _event} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_chore_proof(
         %{"surgical_review" => %{"reviewed_head_sha" => head, "record" => record}},
         _observed,
         head
       )
       when is_binary(record) and record != "",
       do: :ok

  defp validate_chore_proof(_proof, _observed, _head), do: {:error, :malformed_chore_workflow_proof}

  defp validate_final_proof(proof, field, observed, repository_head_sha) when is_map(proof) do
    case successful_fresh_event(observed, proof[field], field, repository_head_sha) do
      {:ok, _event} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_final_proof(_proof, _field, _observed, _head),
    do: {:error, :malformed_final_workflow_proof}

  defp observed_event(observed, event_id, field) when is_binary(event_id) do
    case Map.get(observed, event_id) do
      %{exit_code: exit_code, sequence: sequence} = event
      when is_integer(exit_code) and is_integer(sequence) ->
        {:ok, event}

      nil ->
        {:error, {:unobserved_workflow_proof, field, event_id}}

      _other ->
        {:error, {:malformed_workflow_proof_event, field, event_id}}
    end
  end

  defp observed_event(_observed, _event_id, field), do: {:error, {:missing_workflow_proof_event, field}}

  defp successful_event(observed, event_id, field) do
    with {:ok, event} <- observed_event(observed, event_id, field),
         true <- event.exit_code == 0 || {:error, {:failed_workflow_proof, field, event_id, event.exit_code}} do
      {:ok, event}
    end
  end

  defp successful_fresh_event(observed, event_id, field, repository_head_sha) do
    with {:ok, event} <- successful_event(observed, event_id, field),
         true <-
           event.head_sha == repository_head_sha ||
             {:error, {:stale_workflow_proof, field, event_id, event.head_sha, repository_head_sha}} do
      {:ok, event}
    end
  end

  defp ordered_events(%{sequence: first}, %{sequence: second}, _reason) when first < second, do: :ok
  defp ordered_events(_first, _second, reason), do: {:error, reason}

  defp feature_requires_red?(execution_plan) do
    execution_plan
    |> get_in(["candidate", "evidence_requirements"])
    |> List.wrap()
    |> Enum.any?(&(is_binary(&1) and String.match?(&1, ~r/\bRED\b/i)))
  end

  defp validate_repository_heads(evidence, repository_head_sha, pull_request_head_sha) do
    cond do
      evidence["repository_head_sha"] != repository_head_sha ->
        {:error, {:repository_head_mismatch, evidence["repository_head_sha"], repository_head_sha}}

      evidence["pr_head_sha"] != pull_request_head_sha ->
        {:error, {:pull_request_head_mismatch, evidence["pr_head_sha"], pull_request_head_sha}}

      pull_request_head_sha != repository_head_sha ->
        {:error, {:unpublished_repository_head, repository_head_sha, pull_request_head_sha}}

      true ->
        :ok
    end
  end

  defp validate_pull_request(evidence, workspace, opts) do
    case evidence["pull_request_url"] do
      url when is_binary(url) and url != "" ->
        with {:ok, actual_repository} <- pull_request_repository(url),
             {:ok, origin_url} <- origin_url(workspace, opts),
             {:ok, expected_repository} <- origin_repository(origin_url),
             :ok <- compare_repositories(expected_repository, actual_repository) do
          verify_pull_request(url, workspace, opts)
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
      {:ok, %{url: ^url, head_sha: head_sha}} when is_binary(head_sha) ->
        {:ok, %{url: url, head_sha: head_sha}}

      {:ok, %{url: other_url}} ->
        {:error, {:pull_request_url_mismatch, %{expected: url, actual: other_url}}}

      {:error, reason} ->
        {:error, {:pull_request_unavailable, reason}}

      other ->
        {:error, {:pull_request_verification_failed, other}}
    end
  end

  defp verify_pull_request_with_gh(url, workspace, nil) do
    case System.find_executable("gh") do
      nil ->
        {:error, :github_cli_unavailable}

      executable ->
        case System.cmd(executable, ["pr", "view", url, "--json", "url,headRefOid"],
               cd: workspace,
               stderr_to_stdout: true
             ) do
          {output, 0} -> decode_pull_request(output)
          {output, status} -> {:error, {status, String.trim(output)}}
        end
    end
  end

  defp verify_pull_request_with_gh(url, _workspace, worker_host) when is_binary(worker_host) do
    command = "gh pr view #{shell_escape(url)} --json url,headRefOid"

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {output, 0}} -> decode_pull_request(output)
      {:ok, {output, status}} -> {:error, {worker_host, status, String.trim(output)}}
      {:error, reason} -> {:error, {worker_host, reason}}
    end
  end

  defp decode_pull_request(output) do
    case Jason.decode(output) do
      {:ok, %{"url" => url, "headRefOid" => head_sha}}
      when is_binary(url) and is_binary(head_sha) ->
        {:ok, %{url: url, head_sha: head_sha}}

      {:ok, payload} ->
        {:error, {:malformed_pull_request_response, payload}}

      {:error, reason} ->
        {:error, {:malformed_pull_request_response, reason}}
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
