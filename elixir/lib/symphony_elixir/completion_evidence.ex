defmodule SymphonyElixir.CompletionEvidence do
  @moduledoc "Validates only engine-generated completion evidence from the trusted execution ledger."

  alias SymphonyElixir.{DeliveryControl, EnginePublisher, GitHubRepository, PlanningArtifact, RepositoryFingerprint}
  alias SymphonyElixir.Linear.{Issue, TaskContract}

  @artifact_path Path.join(".symphony", "completion-evidence.json")

  @spec path(Path.t()) :: Path.t()
  def path(workspace), do: Path.join(workspace, @artifact_path)

  @spec validate(Path.t(), Issue.t(), TaskContract.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def validate(workspace, %Issue{} = issue, %TaskContract{} = contract, _agent_proofs, opts \\ []) do
    with {:ok, key} <- ledger_key(opts),
         {:ok, evidence} <- DeliveryControl.read_completion(key),
         {:ok, plan} <- execution_plan(workspace, opts),
         {:ok, head_sha} <- RepositoryFingerprint.head(workspace, Keyword.get(opts, :worker_host)),
         :ok <- validate_identity(evidence, issue, contract, plan, head_sha),
         {:ok, remote_pull_request} <- read_pull_request(workspace, plan, evidence["pull_request_url"], opts),
         :ok <- validate_remote_pull_request(remote_pull_request, evidence, head_sha),
         :ok <- validate_criteria(evidence["criteria"], contract) do
      {:ok,
       %{
         artifact_digest: evidence["receipt_digest"],
         criteria:
           Enum.map(evidence["criteria"], fn criterion ->
             %{
               criterion_id: criterion["criterion_id"],
               proof_event_id: criterion["proof_receipt_digest"]
             }
           end),
         pull_request_url: evidence["pull_request_url"],
         repository_head_sha: head_sha,
         execution_plan_digest: plan["plan_digest"],
         workflow: plan["workflow"],
         profile_digest: plan["profile_digest"]
       }}
    end
  end

  defp ledger_key(opts) do
    case Keyword.get(opts, :execution_ledger_key) do
      key when is_binary(key) -> {:ok, key}
      _ -> {:error, :trusted_execution_ledger_key_missing}
    end
  end

  defp execution_plan(workspace, opts) do
    case Keyword.get(opts, :execution_plan) do
      plan when is_map(plan) ->
        {:ok, plan}

      _ ->
        case PlanningArtifact.read_execution_plan(workspace, Keyword.get(opts, :worker_host)) do
          {:ok, plan} -> {:ok, plan}
          :missing -> {:error, :execution_plan_missing}
          {:error, reason} -> {:error, {:execution_plan_invalid, reason}}
        end
    end
  end

  defp validate_identity(evidence, issue, contract, plan, head_sha) do
    checks = [
      {evidence["schema_version"] == 3, :unsupported_completion_evidence},
      {evidence["issue_id"] == issue.id, :completion_evidence_issue_mismatch},
      {evidence["issue_identifier"] == issue.identifier, :completion_evidence_identifier_mismatch},
      {evidence["contract_digest"] == contract.digest, :completion_evidence_contract_mismatch},
      {evidence["execution_plan_digest"] == plan["plan_digest"], :completion_evidence_plan_mismatch},
      {evidence["instruction_digest"] == plan["instruction_digest"], :completion_evidence_instruction_mismatch},
      {evidence["profile_digest"] == plan["profile_digest"], :completion_evidence_profile_mismatch},
      {evidence["workflow"] == plan["workflow"], :completion_evidence_workflow_mismatch},
      {evidence["repository_head_sha"] == head_sha, :completion_evidence_head_stale},
      {evidence["pr_head_sha"] == head_sha, :completion_evidence_pr_head_stale},
      {is_binary(evidence["pr_head_branch"]), :completion_evidence_pr_branch_invalid},
      {is_binary(evidence["pr_base_branch"]), :completion_evidence_pr_base_invalid},
      {match?({:ok, _}, GitHubRepository.pull_request_url(evidence["pull_request_url"])), :completion_evidence_pr_invalid},
      {pull_request_matches_plan?(evidence["pull_request_url"], plan), :completion_evidence_repository_mismatch}
    ]

    case Enum.find(checks, fn {valid, _reason} -> not valid end) do
      nil -> :ok
      {_valid, reason} -> {:error, reason}
    end
  end

  defp validate_criteria(criteria, contract) when is_list(criteria) do
    expected = Enum.map(contract.acceptance_criteria, & &1.id)
    actual = Enum.map(criteria, & &1["criterion_id"])

    if actual == expected and
         Enum.all?(criteria, &(is_binary(&1["proof_receipt_digest"]) and is_binary(&1["proof_id"]))) do
      :ok
    else
      {:error, :completion_evidence_criteria_mismatch}
    end
  end

  defp validate_criteria(_criteria, _contract), do: {:error, :completion_evidence_criteria_malformed}

  defp read_pull_request(workspace, plan, url, opts) do
    reader = Keyword.get(opts, :pull_request_reader, &EnginePublisher.read_pull_request/4)

    case reader.(workspace, plan, url, opts) do
      {:ok, pull_request} when is_map(pull_request) -> {:ok, pull_request}
      {:error, reason} -> {:error, {:completion_evidence_pr_read_failed, reason}}
      other -> {:error, {:completion_evidence_pr_read_failed, {:invalid_result, other}}}
    end
  end

  defp validate_remote_pull_request(remote, evidence, head_sha) do
    checks = [
      {remote["url"] == evidence["pull_request_url"], :completion_evidence_remote_url_mismatch},
      {remote["state"] == "OPEN", :completion_evidence_pr_not_open},
      {remote["is_cross_repository"] == false, :completion_evidence_cross_repository_pr},
      {remote["head_sha"] == head_sha, :completion_evidence_remote_head_stale},
      {remote["head_branch"] == evidence["pr_head_branch"], :completion_evidence_remote_branch_mismatch},
      {remote["base_branch"] == evidence["pr_base_branch"], :completion_evidence_remote_base_mismatch}
    ]

    case Enum.find(checks, fn {valid, _reason} -> not valid end) do
      nil -> :ok
      {_valid, reason} -> {:error, reason}
    end
  end

  defp pull_request_matches_plan?(url, plan) do
    with {:ok, expected} <- GitHubRepository.from_origin(plan_origin(plan)),
         {:ok, %{repository: actual}} <- GitHubRepository.pull_request_url(url) do
      actual == expected
    else
      _ -> false
    end
  end

  defp plan_origin(%{"candidate" => %{"repository" => %{"origin" => origin}}}), do: origin
  defp plan_origin(%{"repository" => %{"origin" => origin}}), do: origin
  defp plan_origin(_plan), do: nil
end
