defmodule SymphonyElixir.CompletionEvidenceTest do
  use ExUnit.Case, async: true

  import SymphonyElixir.TaskContractFixtures
  alias SymphonyElixir.CompletionEvidence
  alias SymphonyElixir.Linear.TaskContract

  @origin_url "git@github.com:bjornjee/symphony.git"
  @pr_url "https://github.com/bjornjee/symphony/pull/42"

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-completion-evidence-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    task = issue()
    {:ok, contract} = TaskContract.from_issue(task)

    %{workspace: workspace, task: task, contract: contract}
  end

  test "accepts exact criterion coverage backed by engine-observed successful commands", context do
    observed = observed_proofs(context.contract)
    write_evidence(context, valid_evidence(context, observed))

    assert {:ok, %{pull_request_url: @pr_url}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )
  end

  test "rejects a missing completion evidence artifact", context do
    assert {:error, :completion_evidence_missing} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               %{},
               validation_opts()
             )
  end

  test "rejects an oversized engine proof ledger before reading workspace evidence", context do
    observed = Map.new(1..257, &{"proof-#{&1}", %{exit_code: 0}})

    assert {:error, {:observed_proof_limit_exceeded, 256}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )
  end

  test "rejects malformed completion evidence", context do
    File.mkdir_p!(Path.dirname(CompletionEvidence.path(context.workspace)))
    File.write!(CompletionEvidence.path(context.workspace), "not-json")

    assert {:error, {:malformed_completion_evidence, _reason}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               %{},
               validation_opts()
             )
  end

  test "rejects evidence for a stale plan digest", context do
    observed = observed_proofs(context.contract)
    write_evidence(context, %{valid_evidence(context, observed) | "plan_digest" => String.duplicate("0", 64)})

    assert {:error, {:completion_evidence_plan_digest_mismatch, _, _}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )
  end

  test "rejects missing criterion evidence", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    write_evidence(context, %{evidence | "criteria" => Enum.drop(evidence["criteria"], 1)})

    [missing | _] = context.contract.acceptance_criteria
    missing_id = missing.id

    assert {:error, {:missing_criterion_evidence, [^missing_id]}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )
  end

  test "rejects unmatched criterion evidence", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)

    unmatched = %{
      "criterion_id" => "ac-#{String.duplicate("f", 64)}",
      "proof" => %{"kind" => "run_audit_command", "event_id" => "proof-extra"}
    }

    write_evidence(context, %{evidence | "criteria" => evidence["criteria"] ++ [unmatched]})

    assert {:error, {:unmatched_criterion_evidence, [_id]}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               Map.put(observed, "proof-extra", %{exit_code: 0}),
               validation_opts()
             )
  end

  test "rejects duplicate criterion evidence", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    [first | _] = evidence["criteria"]
    write_evidence(context, %{evidence | "criteria" => evidence["criteria"] ++ [first]})

    assert {:error, {:duplicate_criterion_evidence, [first_id]}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )

    assert first_id == first["criterion_id"]
  end

  test "rejects agent-asserted proof absent from the engine ledger", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    [first | rest] = evidence["criteria"]

    forged = put_in(first, ["proof", "event_id"], "agent-asserted-success")
    write_evidence(context, %{evidence | "criteria" => [forged | rest]})

    assert {:error, {:unobserved_criterion_proof, criterion_id, "agent-asserted-success"}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )

    assert criterion_id == first["criterion_id"]
  end

  test "rejects missing pull request URL", context do
    observed = observed_proofs(context.contract)
    evidence = Map.delete(valid_evidence(context, observed), "pull_request_url")
    write_evidence(context, evidence)

    assert {:error, :missing_pull_request_url} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )
  end

  test "rejects malformed and cross-repository pull request URLs", context do
    observed = observed_proofs(context.contract)

    for {url, expected_reason} <- [
          {"https://github.com/bjornjee/symphony/issues/42", :invalid_pull_request_url},
          {"https://github.com/other/project/pull/42", :pull_request_repository_mismatch}
        ] do
      write_evidence(context, %{valid_evidence(context, observed) | "pull_request_url" => url})

      assert {:error, {^expected_reason, _details}} =
               CompletionEvidence.validate(
                 context.workspace,
                 context.task,
                 context.contract,
                 observed,
                 validation_opts()
               )
    end
  end

  test "rejects a pull request URL that the repository host cannot resolve", context do
    observed = observed_proofs(context.contract)
    write_evidence(context, valid_evidence(context, observed))

    opts =
      Keyword.put(validation_opts(), :pull_request_verifier, fn _url, _workspace, _worker_host ->
        {:error, :not_found}
      end)

    assert {:error, {:pull_request_unavailable, :not_found}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               opts
             )
  end

  defp observed_proofs(contract) do
    contract.acceptance_criteria
    |> Enum.with_index(1)
    |> Map.new(fn {_criterion, index} -> {"proof-#{index}", %{exit_code: 0}} end)
  end

  defp valid_evidence(context, observed) do
    proof_ids = Map.keys(observed) |> Enum.sort()

    criteria =
      context.contract.acceptance_criteria
      |> Enum.zip(proof_ids)
      |> Enum.map(fn {criterion, proof_id} ->
        %{
          "criterion_id" => criterion.id,
          "proof" => %{"kind" => "run_audit_command", "event_id" => proof_id}
        }
      end)

    %{
      "schema_version" => 1,
      "issue_id" => context.task.id,
      "issue_identifier" => context.task.identifier,
      "plan_digest" => context.contract.digest,
      "criteria" => criteria,
      "pull_request_url" => @pr_url
    }
  end

  defp write_evidence(context, evidence) do
    path = CompletionEvidence.path(context.workspace)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(evidence))
  end

  defp validation_opts do
    [
      origin_url: @origin_url,
      pull_request_verifier: fn url, _workspace, _worker_host -> {:ok, url} end
    ]
  end
end
