defmodule SymphonyElixir.ProofContract do
  @moduledoc "Validates the typed, bounded proof contract in an approved plan."

  @roles ~w(red green baseline phase final validator)
  @expected_exits ~w(success failure)
  @max_timeout_ms 1_800_000
  @fields ~w(id phase_id role command working_directory expected_exit timeout_ms criterion_ids)
  @unsafe ~r/\bgit(?:\s+-C\s+\S+)?\s+(?:add|am|apply|checkout|clean|commit|config|fetch|merge|mv|pull|push|rebase|reset|restore|revert|rm|switch|tag)\b|\bgit(?:\s+-C\s+\S+)?\s+worktree\s+(?:add|lock|move|prune|remove|repair|unlock)\b|\bgh\s+pr\b|\brm\s+(?:-[^\s]*r[^\s]*f|-[^\s]*f[^\s]*r)\b|\b(?:dropdb|mix\s+ecto\.drop|rails\s+db:drop|tmux\s+send-keys|screen\s+-X\s+stuff)\b|\b(?:psql|mysql)\b.*\bDROP\b/i

  @spec validate([map()], [map()], [String.t()], [String.t()], keyword()) :: :ok | {:error, term()}
  def validate(proofs, phases, criterion_ids, candidate_paths, opts \\ [])
      when is_list(proofs) and is_list(phases) and is_list(criterion_ids) and is_list(candidate_paths) do
    criterion_set = MapSet.new(criterion_ids)

    with :ok <- validate_candidate_paths(candidate_paths),
         :ok <- validate_phases(phases, candidate_paths, criterion_set),
         :ok <- validate_proofs(proofs, MapSet.new(Enum.map(phases, & &1["id"])), criterion_set),
         :ok <- validate_references(proofs, phases),
         :ok <- validate_coverage(proofs, criterion_ids) do
      validate_workflow(proofs, phases, opts)
    end
  end

  defp validate_candidate_paths(paths) do
    if paths != [] and Enum.uniq(paths) == paths and Enum.all?(paths, &safe_repository_path?/1),
      do: :ok,
      else: {:error, :invalid_candidate_paths}
  end

  # Validation is intentionally a single total gate so every malformed phase fails before execution.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_phases(phases, candidate_paths, criterion_ids) do
    Enum.reduce_while(phases, {:ok, MapSet.new()}, fn phase, {:ok, prior} ->
      id = phase["id"]
      dependencies = phase["depends_on"]
      paths = phase["affected_paths"]

      cond do
        not is_binary(id) or MapSet.member?(prior, id) ->
          {:halt, {:error, {:invalid_phase_id, id}}}

        not is_list(dependencies) or not Enum.all?(dependencies, &MapSet.member?(prior, &1)) ->
          {:halt, {:error, {:invalid_phase_dependencies, id}}}

        not is_list(paths) or not Enum.all?(paths, &path_in_scope?(&1, candidate_paths)) ->
          {:halt, {:error, {:phase_paths_outside_candidate_scope, id}}}

        not unique_string_list?(phase["proof_ids"]) ->
          {:halt, {:error, {:invalid_phase_proof_ids, id}}}

        not unique_string_list?(phase["criterion_ids"] || []) or
            not Enum.all?(phase["criterion_ids"] || [], &MapSet.member?(criterion_ids, &1)) ->
          {:halt, {:error, {:invalid_phase_criteria, id}}}

        true ->
          {:cont, {:ok, MapSet.put(prior, id)}}
      end
    end)
    |> case do
      {:ok, _prior} -> :ok
      error -> error
    end
  end

  # Validation is intentionally a single total gate so every malformed proof fails before execution.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_proofs(proofs, phase_ids, criterion_ids) when proofs != [] do
    Enum.reduce_while(proofs, {:ok, MapSet.new()}, fn proof, {:ok, ids} ->
      id = proof["id"]

      error =
        cond do
          Enum.sort(Map.keys(proof)) != Enum.sort(@fields) ->
            {:invalid_proof_fields, id}

          not valid_id?(id) or MapSet.member?(ids, id) ->
            {:duplicate_or_invalid_proof_id, id}

          not MapSet.member?(phase_ids, proof["phase_id"]) ->
            {:invalid_proof_phase, id}

          proof["role"] not in @roles ->
            {:invalid_proof_role, id}

          not valid_command?(proof["command"]) ->
            {:invalid_proof_command, id}

          Regex.match?(@unsafe, proof["command"]) ->
            {:unsafe_proof_command, id}

          not safe_directory?(proof["working_directory"]) ->
            {:invalid_proof_working_directory, id}

          proof["expected_exit"] not in @expected_exits ->
            {:invalid_expected_exit, id}

          not is_integer(proof["timeout_ms"]) or proof["timeout_ms"] not in 1..@max_timeout_ms ->
            {:invalid_proof_timeout, id}

          not unique_string_list?(proof["criterion_ids"]) or
              not Enum.all?(proof["criterion_ids"], &MapSet.member?(criterion_ids, &1)) ->
            {:invalid_proof_criteria, id}

          true ->
            nil
        end

      if error, do: {:halt, {:error, error}}, else: {:cont, {:ok, MapSet.put(ids, id)}}
    end)
    |> case do
      {:ok, _ids} -> :ok
      error -> error
    end
  end

  defp validate_proofs(_proofs, _phase_ids, _criterion_ids), do: {:error, :proofs_required}

  defp validate_references(proofs, phases) do
    proofs_by_id = Map.new(proofs, &{&1["id"], &1})

    Enum.reduce_while(phases, :ok, fn phase, :ok ->
      reference_result(phase, proofs_by_id)
    end)
  end

  defp reference_result(phase, proofs_by_id) do
    expected_phase_id = phase["id"]

    invalid =
      Enum.find(phase["proof_ids"], fn proof_id ->
        not match?(%{"phase_id" => ^expected_phase_id}, proofs_by_id[proof_id])
      end)

    cond do
      is_nil(invalid) -> {:cont, :ok}
      Map.has_key?(proofs_by_id, invalid) -> {:halt, {:error, {:proof_phase_mismatch, invalid, phase["id"]}}}
      true -> {:halt, {:error, {:unknown_proof_id, invalid}}}
    end
  end

  defp validate_coverage(proofs, criterion_ids) do
    covered =
      proofs
      |> Enum.filter(&(&1["role"] in ~w(final validator)))
      |> Enum.flat_map(& &1["criterion_ids"])
      |> MapSet.new()

    case Enum.find(criterion_ids, &(not MapSet.member?(covered, &1))) do
      nil -> :ok
      criterion_id -> {:error, {:uncovered_criterion, criterion_id}}
    end
  end

  # One total workflow gate keeps interdependent proof roles impossible to validate inconsistently.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_workflow(proofs, phases, opts) do
    workflow = Keyword.get(opts, :workflow)
    red_policy = Keyword.get(opts, :red_policy)
    roles = Enum.map(proofs, & &1["role"])

    cond do
      "final" not in roles ->
        {:error, :final_proof_required}

      workflow == "fix" and "red" not in roles ->
        {:error, :fix_red_proof_required}

      workflow == "refactor" and "baseline" not in roles ->
        {:error, :refactor_baseline_required}

      workflow == "refactor" and Enum.any?(phases, &(not refactor_phase_proved?(&1, proofs))) ->
        {:error, :refactor_phase_proof_required}

      workflow == "feature" and red_policy == "required" and "red" not in roles ->
        {:error, :feature_red_proof_required}

      Enum.any?(proofs, &(&1["role"] == "red" and &1["expected_exit"] != "failure")) ->
        {:error, :red_proof_must_expect_failure}

      true ->
        :ok
    end
  end

  defp refactor_phase_proved?(phase, proofs) do
    roles =
      phase["proof_ids"]
      |> Enum.map(fn id -> Enum.find(proofs, &(&1["id"] == id)) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1["role"])

    if "baseline" in roles, do: true, else: Enum.any?(roles, &(&1 in ~w(phase final)))
  end

  defp valid_id?(value), do: is_binary(value) and Regex.match?(~r/^[a-z][a-z0-9_-]{0,63}$/, value)
  defp valid_command?(value), do: is_binary(value) and byte_size(String.trim(value)) in 1..8192

  defp safe_directory?("."), do: true

  defp safe_directory?(path) when is_binary(path),
    do: Path.type(path) == :relative and ".." not in Path.split(path) and not String.contains?(path, <<0>>)

  defp safe_directory?(_path), do: false

  defp unique_string_list?(values) do
    is_list(values) and Enum.uniq(values) == values and
      Enum.all?(values, &(is_binary(&1) and byte_size(&1) in 1..128))
  end

  defp safe_repository_path?(path) do
    is_binary(path) and Path.type(path) == :relative and path not in ["", "."] and
      ".." not in Path.split(path) and not String.contains?(path, [<<0>>, "\\", "*", "?", "[", "]", "{", "}"])
  end

  defp path_in_scope?(path, candidate_paths) do
    safe_repository_path?(path) and
      Enum.any?(candidate_paths, fn candidate ->
        path == candidate or String.starts_with?(path, String.trim_trailing(candidate, "/") <> "/")
      end)
  end
end
