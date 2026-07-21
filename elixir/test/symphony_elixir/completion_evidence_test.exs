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

    assert {:ok,
            %{
              pull_request_url: @pr_url,
              artifact_digest: artifact_digest,
              criteria: criteria
            }} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )

    assert artifact_digest =~ ~r/^[a-f0-9]{64}$/

    assert Enum.map(criteria, & &1.criterion_id) ==
             Enum.map(context.contract.acceptance_criteria, & &1.id)

    assert Enum.all?(criteria, &String.starts_with?(&1.proof_event_id, "proof-"))
  end

  test "keeps semantic artifact identity stable when a retry regenerates proof event ids", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    write_evidence(context, evidence)

    assert {:ok, %{artifact_digest: first_digest}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )

    retried_criteria =
      evidence["criteria"]
      |> Enum.with_index(1)
      |> Enum.map(fn {criterion, index} ->
        put_in(criterion, ["proof", "event_id"], "retry-proof-#{index}")
      end)

    retried_observed =
      Map.new(1..length(retried_criteria), &{"retry-proof-#{&1}", %{exit_code: 0}})

    write_evidence(context, %{evidence | "criteria" => retried_criteria})

    assert {:ok, %{artifact_digest: ^first_digest}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               retried_observed,
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

  test "rejects a non-object completion envelope", context do
    File.mkdir_p!(Path.dirname(CompletionEvidence.path(context.workspace)))
    File.write!(CompletionEvidence.path(context.workspace), "[]")

    assert {:error, {:malformed_completion_evidence, :not_an_object}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               %{},
               validation_opts()
             )
  end

  test "rejects an oversized local completion envelope", context do
    File.mkdir_p!(Path.dirname(CompletionEvidence.path(context.workspace)))
    File.write!(CompletionEvidence.path(context.workspace), String.duplicate("x", 131_073))

    assert {:error, {:completion_evidence_too_large, 131_072}} =
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

  test "rejects unsupported schema and malformed criterion entries", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    write_evidence(context, %{evidence | "schema_version" => 2})

    assert {:error, {:unsupported_completion_evidence_version, 2}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )

    write_evidence(context, %{evidence | "criteria" => [%{} | tl(evidence["criteria"])]})

    assert {:error, :malformed_criterion_evidence} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )
  end

  test "rejects evidence for another issue identity", context do
    expected_issue_id = context.task.id
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    write_evidence(context, %{evidence | "issue_id" => "other-issue"})

    assert {:error, {:completion_evidence_issue_mismatch, "other-issue", ^expected_issue_id}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )
  end

  test "rejects evidence for another issue identifier", context do
    expected_identifier = context.task.identifier
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    write_evidence(context, %{evidence | "issue_identifier" => "OTHER-1"})

    assert {:error, {:completion_evidence_identifier_mismatch, "OTHER-1", ^expected_identifier}} =
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

  test "rejects malformed criterion proof", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    [first | rest] = evidence["criteria"]
    write_evidence(context, %{evidence | "criteria" => [Map.delete(first, "proof") | rest]})

    assert {:error, {:malformed_criterion_proof, criterion_id}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )

    assert criterion_id == first["criterion_id"]
  end

  test "rejects failed and malformed engine observations", context do
    evidence = valid_evidence(context, observed_proofs(context.contract))
    [first, second] = evidence["criteria"]
    first_event = get_in(first, ["proof", "event_id"])
    second_event = get_in(second, ["proof", "event_id"])
    write_evidence(context, evidence)

    assert {:error, {:failed_criterion_proof, _, ^first_event, 1}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               %{first_event => %{exit_code: 1}, second_event => %{exit_code: 0}},
               validation_opts()
             )

    assert {:error, {:malformed_observed_proof, ^first_event}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               %{first_event => :invalid, second_event => %{exit_code: 0}},
               validation_opts()
             )
  end

  test "reads and normalizes the workspace git origin", context do
    System.cmd("git", ["-C", context.workspace, "init", "-b", "main"])

    System.cmd("git", [
      "-C",
      context.workspace,
      "remote",
      "add",
      "origin",
      "https://github.com/bjornjee/symphony.git"
    ])

    observed = observed_proofs(context.contract)
    write_evidence(context, valid_evidence(context, observed))
    opts = Keyword.delete(validation_opts(), :origin_url)

    assert {:ok, %{pull_request_url: @pr_url}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               opts
             )
  end

  test "rejects an unavailable workspace git origin", context do
    observed = observed_proofs(context.contract)
    write_evidence(context, valid_evidence(context, observed))
    opts = Keyword.delete(validation_opts(), :origin_url)

    assert {:error, {:repository_origin_unavailable, {_status, _output}}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               opts
             )
  end

  test "rejects mismatched and malformed PR verifier results", context do
    observed = observed_proofs(context.contract)
    write_evidence(context, valid_evidence(context, observed))

    mismatch_opts =
      Keyword.put(validation_opts(), :pull_request_verifier, fn _, _, _ ->
        {:ok, "https://github.com/bjornjee/symphony/pull/43"}
      end)

    assert {:error, {:pull_request_url_mismatch, _details}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               mismatch_opts
             )

    malformed_opts =
      Keyword.put(validation_opts(), :pull_request_verifier, fn _, _, _ -> :unexpected end)

    assert {:error, {:pull_request_verification_failed, :unexpected}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               malformed_opts
             )
  end

  test "rejects malformed PR numbers and unsupported repository origins", context do
    observed = observed_proofs(context.contract)
    evidence = valid_evidence(context, observed)
    write_evidence(context, %{evidence | "pull_request_url" => "https://github.com/bjornjee/symphony/pull/not-a-number"})

    assert {:error, {:invalid_pull_request_url, _url}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               validation_opts()
             )

    write_evidence(context, evidence)
    opts = Keyword.put(validation_opts(), :origin_url, "https://gitlab.com/bjornjee/symphony.git")

    assert {:error, {:unsupported_repository_origin, _origin}} =
             CompletionEvidence.validate(
               context.workspace,
               context.task,
               context.contract,
               observed,
               opts
             )
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
