defmodule SymphonyElixir.ExecutionControl do
  @moduledoc "Engine-owned proof execution and workflow evidence gates."

  alias SymphonyElixir.{
    Config,
    EngineCommand,
    ExecutionLedger,
    HumanReviewBlocker,
    PlanningArtifact,
    ProofWorkingDirectory,
    RepositoryFingerprint
  }

  alias SymphonyElixir.Linear.{Issue, TaskContract}

  @diagnosis_fields ~w(claim path line_start line_end evidence_summary red_proof_id)

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      tool("run_plan_proof", "Run one exact approved proof through Symphony.", ~w(phase_id proof_id)),
      tool("complete_execution_phase", "Complete one approved phase after its engine proofs pass.", ["phase_id"]),
      %{
        "name" => "submit_fix_diagnosis",
        "description" => "Submit the grounded fix diagnosis after RED and before GREEN.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => @diagnosis_fields,
          "properties" => %{
            "claim" => string_schema(),
            "path" => string_schema(),
            "line_start" => %{"type" => "integer", "minimum" => 1},
            "line_end" => %{"type" => "integer", "minimum" => 1},
            "evidence_summary" => string_schema(),
            "red_proof_id" => string_schema()
          }
        }
      }
    ]
  end

  @spec execute_tool(map(), String.t(), Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute_tool(plan, key, workspace, "run_plan_proof", %{"phase_id" => phase_id, "proof_id" => proof_id}, opts),
    do: run_plan_proof(plan, key, workspace, phase_id, proof_id, opts)

  def execute_tool(plan, key, workspace, "complete_execution_phase", %{"phase_id" => phase_id}, opts),
    do: complete_execution_phase(plan, key, workspace, phase_id, opts)

  def execute_tool(plan, key, _workspace, "submit_fix_diagnosis", arguments, _opts),
    do: submit_fix_diagnosis(plan, key, arguments)

  def execute_tool(_plan, _key, _workspace, tool, _arguments, _opts), do: {:error, {:unsupported_execution_tool, tool}}

  @spec run_plan_proof(map(), String.t(), Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run_plan_proof(plan, ledger_key, workspace, phase_id, proof_id, opts \\ []) do
    with {:ok, proof} <- find_proof(plan, phase_id, proof_id),
         {:ok, generation, attempt} <- next_attempt(ledger_key, proof_id),
         {:ok, proof_directory} <-
           ProofWorkingDirectory.resolve(
             workspace,
             proof["working_directory"],
             Keyword.get(opts, :worker_host)
           ),
         {:ok, before} <- RepositoryFingerprint.capture(workspace, Keyword.get(opts, :worker_host)),
         :ok <- workflow_preconditions(plan, ledger_key, proof, before),
         command_result <-
           EngineCommand.run(proof_directory, proof["command"],
             timeout_ms: min(proof["timeout_ms"], 1_800_000),
             executor: Keyword.get(opts, :command_executor)
           ),
         {:ok, after_state} <- RepositoryFingerprint.capture(workspace, Keyword.get(opts, :worker_host)) do
      {result, runner_error} = normalize_command_result(command_result)
      freshness_error = proof_freshness_error(proof, before, after_state, execution_base(plan))
      passed = is_nil(runner_error) and is_nil(freshness_error) and expected_exit?(proof["expected_exit"], result.exit_status)

      receipt = %{
        "plan_digest" => plan["plan_digest"],
        "instruction_digest" => plan["instruction_digest"],
        "profile_digest" => plan["profile_digest"],
        "proof_id" => proof_id,
        "proof_digest" => PlanningArtifact.digest(proof),
        "phase_id" => phase_id,
        "role" => proof["role"],
        "criterion_ids" => proof["criterion_ids"],
        "generation" => generation,
        "attempt" => attempt,
        "attempts_remaining" => 3 - attempt,
        "expected_exit" => proof["expected_exit"],
        "exit_status" => result.exit_status,
        "passed" => passed,
        "runner_error" => runner_error,
        "freshness_error" => freshness_error,
        "output_bytes" => result.output_bytes,
        "output_hash" => result.output_hash,
        "diagnostic_tail" => result.output_tail,
        "before_state_digest" => before.digest,
        "after_state_digest" => after_state.digest,
        "head_sha" => after_state.base_sha,
        "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      case ExecutionLedger.create(
             ledger_key,
             "proof",
             proof_receipt_id(proof_id, generation, attempt),
             receipt
           ) do
        {:ok, persisted} -> {:ok, persisted}
        :exists -> {:error, :proof_attempt_collision}
        {:error, reason} -> {:error, {:proof_receipt_failed, reason}}
      end
    end
  end

  @spec exhausted_proof(map(), String.t()) ::
          :none | {:ok, %{proof: map(), last_receipt: map()}} | {:error, term()}
  def exhausted_proof(plan, ledger_key) do
    proofs = get_in(plan, ["candidate", "proofs"]) || plan["proofs"] || []

    Enum.reduce_while(proofs, :none, fn proof, _none ->
      ledger_key
      |> proof_receipts(proof["id"])
      |> reduce_exhausted_proof(proof)
    end)
  end

  @spec resume_exhausted_proof(map(), String.t(), Path.t(), keyword()) ::
          :none | {:ok, map()} | {:error, term()}
  def resume_exhausted_proof(plan, ledger_key, workspace, opts \\ []) do
    case exhausted_proof(plan, ledger_key) do
      :none ->
        :none

      {:ok, %{proof: proof, last_receipt: last_receipt}} ->
        resume_proof_generation(
          ledger_key,
          proof,
          last_receipt,
          workspace,
          Keyword.get(opts, :worker_host)
        )

      {:error, _reason} = error ->
        error
    end
  end

  @spec block_on_exhausted_proof(map(), String.t(), Issue.t(), TaskContract.t(), keyword()) ::
          :none | {:ok, map()} | {:error, term()}
  def block_on_exhausted_proof(plan, ledger_key, issue, contract, opts \\ []) do
    case exhausted_proof(plan, ledger_key) do
      :none ->
        :none

      {:ok, %{proof: proof, last_receipt: receipt}} ->
        publish_proof_exhaustion(issue, contract, plan, proof, receipt, opts)

      {:error, _reason} = error ->
        error
    end
  end

  @spec submit_fix_diagnosis(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def submit_fix_diagnosis(%{"workflow" => "fix"} = plan, ledger_key, diagnosis) do
    with true <- Enum.sort(Map.keys(diagnosis)) == Enum.sort(@diagnosis_fields) || {:error, :invalid_diagnosis_fields},
         true <- valid_diagnosis?(diagnosis) || {:error, :invalid_fix_diagnosis},
         {:ok, red} <- latest_passed(ledger_key, diagnosis["red_proof_id"]),
         true <- red["role"] == "red" || {:error, :diagnosis_red_proof_required} do
      receipt = Map.merge(diagnosis, %{"plan_digest" => plan["plan_digest"], "red_receipt_digest" => red["receipt_digest"]})

      case ExecutionLedger.create(ledger_key, "diagnosis", "fix", receipt) do
        {:ok, persisted} ->
          {:ok, persisted}

        :exists ->
          ExecutionLedger.read_required(
            ledger_key,
            "diagnosis",
            "fix",
            :diagnosis_receipt_missing,
            :diagnosis_receipt_invalid
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def submit_fix_diagnosis(_plan, _ledger_key, _diagnosis), do: {:error, :diagnosis_not_allowed}

  @spec delivery_state(map(), String.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delivery_state(plan, ledger_key, workspace, opts \\ []) do
    with :ok <- all_phases_completed(plan, ledger_key),
         {:ok, state} <- RepositoryFingerprint.capture(workspace, Keyword.get(opts, :worker_host)),
         true <- state.clean || {:error, :delivery_requires_clean_tree},
         {:ok, changed_paths} <-
           RepositoryFingerprint.changed_paths(
             workspace,
             execution_base(plan),
             Keyword.get(opts, :worker_host)
           ),
         :ok <- paths_within_approved_scope(changed_paths, approved_paths(plan)),
         {:ok, final} <- latest_role(plan, ledger_key, "final"),
         true <- final["passed"] || {:error, :final_proof_failed},
         true <- final["after_state_digest"] == state.digest || {:error, :final_proof_stale},
         true <- final["head_sha"] == state.base_sha || {:error, :final_proof_head_stale},
         :ok <- workflow_delivery_evidence(plan, ledger_key),
         :ok <- ensure_surgical_chore_review(plan, ledger_key, workspace, state, opts) do
      {:ok, %{repository: state, final_proof: final, changed_paths: changed_paths}}
    end
  end

  @spec complete_execution_phase(map(), String.t(), Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete_execution_phase(plan, ledger_key, workspace, phase_id, opts \\ []) do
    phases = get_in(plan, ["candidate", "ordered_steps"]) || []

    with %{} = phase <- Enum.find(phases, &(&1["id"] == phase_id)) || {:error, :unknown_execution_phase},
         :ok <- completed_dependencies(ledger_key, phase["depends_on"]),
         {:ok, proof_receipts} <- completed_proofs(ledger_key, phase["proof_ids"]),
         :ok <- proof_receipts_in_order(proof_receipts),
         {:ok, state} <- RepositoryFingerprint.capture(workspace, Keyword.get(opts, :worker_host)),
         true <- state.digest == List.last(proof_receipts)["after_state_digest"] || {:error, :repository_changed_after_proof},
         {:ok, changed_paths} <- RepositoryFingerprint.changed_paths(workspace, execution_base(plan), Keyword.get(opts, :worker_host)),
         :ok <- paths_within_phase_scope(changed_paths, phases, phase_id) do
      receipt = %{
        "plan_digest" => plan["plan_digest"],
        "phase_id" => phase_id,
        "proof_receipt_digests" => Enum.map(proof_receipts, & &1["receipt_digest"]),
        "repository_state_digest" => state.digest,
        "head_sha" => state.base_sha,
        "changed_paths" => changed_paths
      }

      case ExecutionLedger.create(ledger_key, "phase", phase_id, receipt) do
        {:ok, persisted} ->
          {:ok, persisted}

        :exists ->
          ExecutionLedger.read_required(
            ledger_key,
            "phase",
            phase_id,
            :phase_receipt_missing,
            :phase_receipt_invalid
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp find_proof(plan, phase_id, proof_id) do
    proofs = get_in(plan, ["candidate", "proofs"]) || plan["proofs"] || []

    case Enum.find(proofs, &(&1["id"] == proof_id and &1["phase_id"] == phase_id)) do
      nil -> {:error, :unknown_phase_proof}
      proof -> {:ok, proof}
    end
  end

  defp workflow_preconditions(%{"workflow" => "fix"}, ledger_key, %{"role" => role}, _state)
       when role in ~w(green final) do
    case ExecutionLedger.read(ledger_key, "diagnosis", "fix") do
      {:ok, _receipt} -> :ok
      _ -> {:error, :fix_diagnosis_required}
    end
  end

  defp workflow_preconditions(%{"workflow" => "feature"} = plan, ledger_key, %{"role" => role}, _state)
       when role not in ~w(red baseline) do
    if get_in(plan, ["candidate", "red_policy"]) == "required", do: require_role(plan, ledger_key, "red"), else: :ok
  end

  defp workflow_preconditions(%{"workflow" => "refactor"} = plan, ledger_key, %{"role" => role}, _state)
       when role != "baseline",
       do: require_role(plan, ledger_key, "baseline")

  defp workflow_preconditions(_plan, _ledger_key, _proof, _state), do: :ok

  defp next_attempt(key, proof_id) do
    with {:ok, generation} <- proof_generation(key, proof_id) do
      case Enum.find(
             1..3,
             &(ExecutionLedger.read(
                 key,
                 "proof",
                 proof_receipt_id(proof_id, generation, &1)
               ) == :missing)
           ) do
        nil -> {:error, :proof_attempts_exhausted}
        attempt -> {:ok, generation, attempt}
      end
    end
  end

  defp latest_passed(key, proof_id) do
    with {:ok, receipts} <- proof_receipts(key, proof_id) do
      receipts
      |> Enum.reverse()
      |> Enum.find(& &1["passed"])
      |> case do
        nil -> {:error, :passed_proof_required}
        receipt -> {:ok, receipt}
      end
    end
  end

  defp open_proof_generation(key, proof_id, last_receipt, repository) do
    with {:ok, current_generation} <- proof_generation(key, proof_id) do
      generation = current_generation + 1

      receipt = %{
        "proof_id" => proof_id,
        "generation" => generation,
        "previous_generation" => current_generation,
        "previous_receipt_digest" => last_receipt["receipt_digest"],
        "repository_state_digest" => repository.digest,
        "head_sha" => repository.base_sha
      }

      case ExecutionLedger.create(
             key,
             "proof-generation",
             "#{proof_id}-#{generation}",
             receipt
           ) do
        {:ok, persisted} ->
          {:ok, persisted}

        :exists ->
          validate_existing_generation(key, proof_id, generation, receipt)

        {:error, reason} ->
          {:error, {:proof_generation_receipt_failed, reason}}
      end
    end
  end

  defp validate_existing_generation(key, proof_id, generation, receipt) do
    case ExecutionLedger.read(
           key,
           "proof-generation",
           "#{proof_id}-#{generation}"
         ) do
      {:ok, existing} ->
        if Map.drop(existing, ["receipt_digest"]) == receipt,
          do: {:ok, existing},
          else: {:error, :proof_generation_collision}

      other ->
        {:error, {:proof_generation_receipt_invalid, other}}
    end
  end

  defp proof_generation(key, proof_id) do
    case ExecutionLedger.list(key, "proof-generation") do
      {:ok, receipts} ->
        validate_proof_generations(receipts, proof_id)

      {:error, reason} ->
        {:error, {:proof_generation_receipt_invalid, reason}}
    end
  end

  defp validate_proof_generations(receipts, proof_id) do
    generations =
      receipts
      |> Enum.filter(&(&1["proof_id"] == proof_id))
      |> Enum.map(& &1["generation"])
      |> Enum.sort()

    if Enum.all?(receipts, &valid_proof_generation_receipt?/1) and
         contiguous_proof_generations?(generations),
       do: {:ok, List.last(generations) || 1},
       else: {:error, :proof_generation_receipt_invalid}
  end

  defp valid_proof_generation_receipt?(receipt) when is_map(receipt) do
    generation = receipt["generation"]

    is_binary(receipt["proof_id"]) and
      is_integer(generation) and
      generation >= 2 and
      receipt["previous_generation"] == generation - 1 and
      is_binary(receipt["previous_receipt_digest"]) and
      is_binary(receipt["repository_state_digest"]) and
      is_binary(receipt["head_sha"])
  end

  defp valid_proof_generation_receipt?(_receipt), do: false

  defp contiguous_proof_generations?([]), do: true

  defp contiguous_proof_generations?(generations),
    do: generations == Enum.to_list(2..List.last(generations))

  defp proof_receipts(key, proof_id) do
    with {:ok, generation} <- proof_generation(key, proof_id) do
      read_proof_receipts(key, proof_id, generation)
    end
  end

  defp reduce_exhausted_proof({:ok, receipts}, proof) do
    cond do
      Enum.any?(receipts, &(not receipt_matches_proof?(&1, proof))) ->
        {:halt, {:error, :proof_receipt_drift}}

      length(receipts) == 3 and Enum.all?(receipts, &(not &1["passed"])) ->
        {:halt, {:ok, %{proof: proof, last_receipt: List.last(receipts)}}}

      true ->
        {:cont, :none}
    end
  end

  defp reduce_exhausted_proof({:error, :proof_generation_receipt_invalid}, _proof),
    do: {:halt, {:error, :proof_generation_receipt_invalid}}

  defp reduce_exhausted_proof({:error, _reason}, _proof),
    do: {:halt, {:error, :proof_receipt_invalid}}

  defp resume_proof_generation(ledger_key, proof, last_receipt, workspace, worker_host) do
    with {:ok, repository} <- RepositoryFingerprint.capture(workspace, worker_host) do
      maybe_open_proof_generation(ledger_key, proof, last_receipt, repository)
    end
  end

  defp maybe_open_proof_generation(ledger_key, proof, last_receipt, repository) do
    if repository.digest == last_receipt["after_state_digest"],
      do: :none,
      else: open_proof_generation(ledger_key, proof["id"], last_receipt, repository)
  end

  defp read_proof_receipts(key, proof_id, generation) do
    Enum.reduce_while(1..3, {:ok, []}, fn attempt, {:ok, receipts} ->
      case ExecutionLedger.read(
             key,
             "proof",
             proof_receipt_id(proof_id, generation, attempt)
           ) do
        {:ok, receipt} -> {:cont, {:ok, receipts ++ [receipt]}}
        :missing -> {:cont, {:ok, receipts}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp proof_receipt_id(proof_id, 1, attempt),
    do: "#{proof_id}-#{attempt}"

  defp proof_receipt_id(proof_id, generation, attempt),
    do: "#{proof_id}-g#{generation}-#{attempt}"

  defp receipt_matches_proof?(receipt, proof) when is_map(receipt) and is_map(proof) do
    receipt["proof_id"] == proof["id"] and
      receipt["proof_digest"] == PlanningArtifact.digest(proof)
  end

  defp receipt_matches_proof?(_receipt, _proof), do: false

  defp publish_proof_exhaustion(issue, contract, plan, proof, receipt, opts) do
    detail =
      receipt["runner_error"] ||
        receipt["freshness_error"] ||
        "exit status #{receipt["exit_status"]} did not match #{receipt["expected_exit"]}"

    body =
      """
      ## Agent Blocked

      Engine proof `#{proof["id"]}` failed all three approved attempts. Symphony stopped automatic execution to prevent a retry loop.

      Last failure: #{detail}.

      Review the repository-owned verification command or its execution environment, then explicitly redispatch the issue after correcting the contract or implementation.

      <!-- symphony-proof-exhausted:v1 plan=#{plan["plan_digest"]} proof=#{proof["id"]} -->
      """
      |> String.trim()

    case HumanReviewBlocker.publish(
           issue,
           [contract.digest, plan["plan_digest"], proof["id"], "proof-exhausted"],
           body,
           opts
         ) do
      {:ok, comment_id} ->
        {:ok,
         %{
           continuation: :done,
           outcome: :human_review_required,
           blocker_comment_id: comment_id,
           blocker_proof_id: proof["id"],
           blocker_receipt_digest: receipt["receipt_digest"],
           issue_state: Keyword.get_lazy(opts, :handoff_state, fn -> Config.settings!().tracker.handoff_state end),
           issue_active: false,
           issue_routable: false,
           issue_labels: issue.labels
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp latest_role(plan, key, role) do
    (get_in(plan, ["candidate", "proofs"]) || plan["proofs"] || [])
    |> Enum.filter(&(&1["role"] == role))
    |> Enum.reduce_while({:error, {:proof_role_required, role}}, fn proof, _acc ->
      case latest_passed(key, proof["id"]) do
        {:ok, receipt} -> {:halt, {:ok, receipt}}
        _ -> {:cont, {:error, {:proof_role_required, role}}}
      end
    end)
  end

  defp all_phases_completed(%{"execution_mode" => "simple"}, _key), do: :ok

  defp all_phases_completed(plan, key) do
    phases = get_in(plan, ["candidate", "ordered_steps"]) || []

    case Enum.find(phases, &(not match?({:ok, _}, ExecutionLedger.read(key, "phase", &1["id"])))) do
      nil -> :ok
      phase -> {:error, {:execution_phase_incomplete, phase["id"]}}
    end
  end

  defp workflow_delivery_evidence(%{"workflow" => "fix"}, key) do
    with {:ok, _red} <- find_role_receipt(key, "red"),
         {:ok, _diagnosis} <- require_receipt(key, "diagnosis", "fix") do
      :ok
    end
  end

  defp workflow_delivery_evidence(%{"workflow" => "refactor"}, key) do
    with {:ok, _baseline} <- find_role_receipt(key, "baseline"), do: :ok
  end

  defp workflow_delivery_evidence(%{"workflow" => "feature", "candidate" => %{"red_policy" => "required"}}, key) do
    with {:ok, _red} <- find_role_receipt(key, "red"), do: :ok
  end

  defp workflow_delivery_evidence(_plan, _key), do: :ok

  defp ensure_surgical_chore_review(
         %{"workflow" => "chore", "candidate" => %{"verification_profile" => "Surgical"}} = plan,
         key,
         workspace,
         state,
         opts
       ) do
    with {:ok, changed_paths} <-
           RepositoryFingerprint.changed_paths(workspace, execution_base(plan), Keyword.get(opts, :worker_host)),
         true <-
           Enum.all?(changed_paths, &approved_path?(&1, get_in(plan, ["candidate", "affected_paths"]))) ||
             {:error, :surgical_review_scope_drift} do
      receipt = %{
        "plan_digest" => plan["plan_digest"],
        "head_sha" => state.base_sha,
        "repository_state_digest" => state.digest,
        "changed_paths" => changed_paths,
        "record" => "Deterministic diff scope review passed."
      }

      persist_surgical_review(key, receipt)
    end
  end

  defp ensure_surgical_chore_review(_plan, _key, _workspace, _state, _opts), do: :ok

  defp persist_surgical_review(key, receipt) do
    case ExecutionLedger.create(key, "surgical-review", "final", receipt) do
      {:ok, _persisted} -> :ok
      :exists -> validate_existing_surgical_review(key, receipt)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_existing_surgical_review(key, receipt) do
    case ExecutionLedger.read(key, "surgical-review", "final") do
      {:ok, existing} ->
        if Map.drop(existing, ["receipt_digest"]) == receipt,
          do: :ok,
          else: {:error, :surgical_review_drift}

      other ->
        {:error, {:surgical_review_invalid, other}}
    end
  end

  defp find_role_receipt(key, role) do
    with {:ok, receipts} <- ExecutionLedger.list(key, "proof") do
      case Enum.find(receipts, &(&1["role"] == role and &1["passed"])) do
        nil -> {:error, {:proof_role_required, role}}
        receipt -> {:ok, receipt}
      end
    end
  end

  defp require_receipt(key, kind, id) do
    case ExecutionLedger.read(key, kind, id) do
      {:ok, receipt} -> {:ok, receipt}
      _ -> {:error, {String.to_atom("#{kind}_receipt_required"), id}}
    end
  end

  defp completed_dependencies(key, dependencies) do
    case Enum.find(dependencies, &(not match?({:ok, _}, ExecutionLedger.read(key, "phase", &1)))) do
      nil -> :ok
      dependency -> {:error, {:phase_dependency_incomplete, dependency}}
    end
  end

  defp completed_proofs(key, proof_ids) do
    Enum.reduce_while(proof_ids, {:ok, []}, fn proof_id, {:ok, receipts} ->
      case latest_passed(key, proof_id) do
        {:ok, receipt} -> {:cont, {:ok, receipts ++ [receipt]}}
        _ -> {:halt, {:error, {:phase_proof_incomplete, proof_id}}}
      end
    end)
  end

  defp paths_within_phase_scope(changed, phases, phase_id) do
    allowed =
      phases
      |> Enum.take_while(fn phase -> phase["id"] != phase_id end)
      |> Kernel.++([Enum.find(phases, &(&1["id"] == phase_id))])
      |> Enum.flat_map(& &1["affected_paths"])

    case Enum.find(changed, &(not approved_path?(&1, allowed))) do
      nil -> :ok
      path -> {:error, {:changed_path_outside_phase_scope, path}}
    end
  end

  defp paths_within_approved_scope(changed, allowed) do
    case Enum.find(changed, &(not approved_path?(&1, allowed))) do
      nil -> :ok
      path -> {:error, {:changed_path_outside_approved_scope, path}}
    end
  end

  defp approved_paths(%{"candidate" => %{"affected_paths" => paths}}), do: paths
  defp approved_paths(%{"affected_paths" => paths}), do: paths
  defp approved_paths(_plan), do: []

  defp approved_path?(changed_path, allowed) do
    Enum.any?(allowed, fn path ->
      changed_path == path or String.starts_with?(changed_path, String.trim_trailing(path, "/") <> "/")
    end)
  end

  defp proof_receipts_in_order(receipts) do
    timestamps = Enum.map(receipts, & &1["recorded_at"])
    if timestamps == Enum.sort(timestamps), do: :ok, else: {:error, :phase_proofs_out_of_order}
  end

  defp execution_base(plan), do: get_in(plan, ["candidate", "repository", "base_sha"]) || get_in(plan, ["repository", "base_sha"])

  defp proof_freshness_error(%{"role" => "baseline"}, before, after_state, base_sha) do
    if before.clean and after_state.clean and before.digest == after_state.digest and before.base_sha == base_sha,
      do: nil,
      else: "preimplementation_proof_requires_clean_stable_base"
  end

  defp proof_freshness_error(%{"role" => "red"}, before, after_state, base_sha) do
    if before.digest == after_state.digest and before.base_sha == base_sha,
      do: nil,
      else: "red_proof_requires_stable_pinned_head"
  end

  defp proof_freshness_error(%{"role" => "final"}, before, after_state, _base_sha) do
    if before.clean and after_state.clean and before.digest == after_state.digest,
      do: nil,
      else: "final_proof_requires_clean_stable_tree"
  end

  defp proof_freshness_error(_proof, _before, _after, _base_sha), do: nil

  defp expected_exit?("success", 0), do: true
  defp expected_exit?("failure", status), do: status != 0
  defp expected_exit?(_expected, _status), do: false

  defp normalize_command_result({:ok, result}), do: {Map.put(result, :exit_status, result.exit_status), nil}

  defp normalize_command_result({:error, result}) when is_map(result) do
    {Map.put(result, :exit_status, nil), to_string(result.reason)}
  end

  defp normalize_command_result({:error, reason}) do
    {%{exit_status: nil, output_bytes: 0, output_hash: PlanningArtifact.digest(""), output_tail: ""}, inspect(reason)}
  end

  defp require_role(plan, key, role) do
    proof_ids =
      (get_in(plan, ["candidate", "proofs"]) || [])
      |> Enum.filter(&(&1["role"] == role))
      |> Enum.map(& &1["id"])

    if Enum.any?(proof_ids, &match?({:ok, _}, latest_passed(key, &1))),
      do: :ok,
      else: {:error, {String.to_atom("#{role}_proof_required"), role}}
  end

  defp valid_diagnosis?(diagnosis) do
    Enum.all?(~w(claim path evidence_summary red_proof_id), &(is_binary(diagnosis[&1]) and String.trim(diagnosis[&1]) != "")) and
      is_integer(diagnosis["line_start"]) and diagnosis["line_start"] > 0 and
      is_integer(diagnosis["line_end"]) and diagnosis["line_end"] >= diagnosis["line_start"] and
      Path.type(diagnosis["path"]) == :relative and ".." not in Path.split(diagnosis["path"])
  end

  defp tool(name, description, required) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "required" => required, "properties" => Map.new(required, &{&1, string_schema()})}
    }
  end

  defp string_schema, do: %{"type" => "string", "minLength" => 1, "maxLength" => 8192}
end
