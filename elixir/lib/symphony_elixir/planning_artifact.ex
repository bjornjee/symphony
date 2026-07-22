defmodule SymphonyElixir.PlanningArtifact do
  @moduledoc """
  Validates and persists the immutable artifacts in the preactivation planning lifecycle.
  """

  alias SymphonyElixir.WorkspaceArtifact

  @schema_version 1
  @artifact_dir ".symphony"
  @max_candidate_bytes 65_536
  @max_review_bytes 32_768
  @max_execution_plan_bytes 98_304
  @max_items 64
  @candidate_fields ~w(
    issue_id issue_identifier contract_digest workflow profile_digest primary_thread_id
    ordered_steps affected_paths scope execution_context scale_shape verification_profile
    proof_commands risks invariants rollback evidence_requirements repository
  )
  @review_fields ~w(
    candidate_digest verdict blocking_findings advisory_findings workflow profile_digest
  )
  @phase_fields ~w(
    id step status affected_paths depends_on verification_profile proof_commands invariants
    stop_conditions evidence_requirements
  )

  @spec candidate_tool_specs() :: [map()]
  def candidate_tool_specs do
    [
      %{
        "name" => "submit_execution_plan",
        "description" => "Submit the complete bounded execution-plan candidate. Call this exactly once after the final native plan update.",
        "inputSchema" => candidate_schema()
      }
    ]
  end

  @spec review_tool_specs() :: [map()]
  def review_tool_specs do
    [
      %{
        "name" => "submit_plan_review",
        "description" => "Submit one schema-constrained review of the exact plan candidate.",
        "inputSchema" => review_schema()
      }
    ]
  end

  @spec persist_candidate(Path.t(), 1..3, map(), map(), [map()], String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def persist_candidate(workspace, revision, candidate, context, native_plan, worker_host \\ nil)
      when is_binary(workspace) and revision in 1..3 do
    with :ok <- validate_exact_fields(candidate, @candidate_fields),
         :ok <- validate_context(candidate, context),
         :ok <- validate_candidate_content(candidate),
         :ok <- validate_native_plan(candidate["ordered_steps"], native_plan) do
      persisted =
        candidate
        |> Map.put("schema_version", @schema_version)
        |> Map.put("revision", revision)
        |> Map.put("candidate_digest", digest(candidate))

      persist_new(
        candidate_path(workspace, revision),
        persisted,
        @max_candidate_bytes,
        {:candidate_already_exists, revision},
        worker_host
      )
    end
  end

  @spec persist_review(Path.t(), 1..3, map(), map(), map(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def persist_review(workspace, revision, review, candidate, context, worker_host \\ nil)
      when is_binary(workspace) and revision in 1..3 do
    with :ok <- validate_exact_fields(review, @review_fields),
         :ok <- validate_review(review, candidate, context) do
      persisted =
        review
        |> Map.put("schema_version", @schema_version)
        |> Map.put("revision", revision)
        |> Map.put("review_digest", digest(review))

      persist_new(
        review_path(workspace, revision),
        persisted,
        @max_review_bytes,
        {:review_already_exists, revision},
        worker_host
      )
    end
  end

  @spec seal(Path.t(), map(), map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def seal(workspace, candidate, review, worker_host \\ nil) when is_binary(workspace) do
    with :ok <- validate_approval(candidate, review) do
      semantic = %{
        "schema_version" => @schema_version,
        "issue_id" => candidate["issue_id"],
        "issue_identifier" => candidate["issue_identifier"],
        "contract_digest" => candidate["contract_digest"],
        "workflow" => candidate["workflow"],
        "profile_digest" => candidate["profile_digest"],
        "primary_thread_id" => candidate["primary_thread_id"],
        "revision" => candidate["revision"],
        "candidate_digest" => candidate["candidate_digest"],
        "review_digest" => review["review_digest"],
        "candidate" => Map.drop(candidate, ["schema_version", "revision", "candidate_digest"]),
        "review" => Map.drop(review, ["schema_version", "revision", "review_digest"])
      }

      execution_plan = Map.put(semantic, "plan_digest", digest(semantic))

      case persist_new(
             execution_plan_path(workspace),
             execution_plan,
             @max_execution_plan_bytes,
             :execution_plan_already_exists,
             worker_host
           ) do
        {:error, :execution_plan_already_exists} ->
          validate_existing_execution_plan(workspace, execution_plan, worker_host)

        result ->
          result
      end
    end
  end

  @spec seal_simple(Path.t(), map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def seal_simple(workspace, %{"category" => "simple"} = classification, worker_host \\ nil)
      when is_binary(workspace) do
    semantic = %{
      "schema_version" => @schema_version,
      "execution_mode" => "simple",
      "issue_id" => classification["issue_id"],
      "issue_identifier" => classification["issue_identifier"],
      "contract_digest" => classification["contract_digest"],
      "workflow" => classification["workflow"],
      "profile_digest" => classification["profile_digest"],
      "primary_thread_id" => classification["primary_thread_id"],
      "classification_digest" => classification["classification_digest"],
      "repository" => classification["repository"],
      "affected_paths" => classification["affected_paths"],
      "proof_commands" => classification["proof_commands"],
      "verification_profile" => "Targeted"
    }

    execution_plan = Map.put(semantic, "plan_digest", digest(semantic))

    case persist_new(
           execution_plan_path(workspace),
           execution_plan,
           @max_execution_plan_bytes,
           :execution_plan_already_exists,
           worker_host
         ) do
      {:error, :execution_plan_already_exists} ->
        validate_existing_execution_plan(workspace, execution_plan, worker_host)

      result ->
        result
    end
  end

  @spec read_candidate(Path.t(), 1..3, String.t() | nil) :: :missing | {:ok, map()} | {:error, term()}
  def read_candidate(workspace, revision, worker_host \\ nil) when revision in 1..3 do
    read_json(candidate_path(workspace, revision), @max_candidate_bytes, worker_host)
  end

  @spec read_review(Path.t(), 1..3, String.t() | nil) :: :missing | {:ok, map()} | {:error, term()}
  def read_review(workspace, revision, worker_host \\ nil) when revision in 1..3 do
    read_json(review_path(workspace, revision), @max_review_bytes, worker_host)
  end

  @spec read_execution_plan(Path.t(), String.t() | nil) :: :missing | {:ok, map()} | {:error, term()}
  def read_execution_plan(workspace, worker_host \\ nil) do
    read_json(execution_plan_path(workspace), @max_execution_plan_bytes, worker_host)
  end

  @spec candidate_path(Path.t(), 1..3) :: Path.t()
  def candidate_path(workspace, revision),
    do: Path.join([workspace, @artifact_dir, "plan-candidate-#{revision}.json"])

  @spec review_path(Path.t(), 1..3) :: Path.t()
  def review_path(workspace, revision),
    do: Path.join([workspace, @artifact_dir, "plan-review-#{revision}.json"])

  @spec execution_plan_path(Path.t()) :: Path.t()
  def execution_plan_path(workspace),
    do: Path.join([workspace, @artifact_dir, "execution-plan.json"])

  @spec digest(term()) :: String.t()
  def digest(value) do
    value
    |> canonical_term()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp validate_exact_fields(value, fields) when is_map(value) do
    actual = value |> Map.keys() |> Enum.sort()
    expected = Enum.sort(fields)
    if actual == expected, do: :ok, else: {:error, {:invalid_artifact_fields, expected, actual}}
  end

  defp validate_exact_fields(_value, _fields), do: {:error, :artifact_not_an_object}

  defp validate_context(candidate, context) do
    mismatches =
      ~w(issue_id issue_identifier contract_digest workflow profile_digest primary_thread_id repository)
      |> Enum.reject(&(candidate[&1] == context[&1]))

    if mismatches == [], do: :ok, else: {:error, {:candidate_context_mismatch, mismatches}}
  end

  defp validate_candidate_content(candidate) do
    with :ok <- nonempty_string(candidate["issue_id"], "issue_id"),
         :ok <- nonempty_string(candidate["issue_identifier"], "issue_identifier"),
         :ok <- digest_string(candidate["contract_digest"], "contract_digest"),
         :ok <- workflow(candidate["workflow"]),
         :ok <- digest_string(candidate["profile_digest"], "profile_digest"),
         :ok <- nonempty_string(candidate["primary_thread_id"], "primary_thread_id"),
         :ok <- ordered_steps(candidate["ordered_steps"]),
         :ok <- string_list(candidate["affected_paths"], "affected_paths", false),
         :ok <- scope(candidate["scope"]),
         :ok <- nonempty_string(candidate["execution_context"], "execution_context"),
         :ok <- nonempty_string(candidate["scale_shape"], "scale_shape"),
         :ok <- verification_profile(candidate["verification_profile"]),
         :ok <- string_list(candidate["proof_commands"], "proof_commands", false),
         :ok <- string_list(candidate["risks"], "risks", true),
         :ok <- string_list(candidate["invariants"], "invariants", false),
         :ok <- nonempty_string(candidate["rollback"], "rollback"),
         :ok <- string_list(candidate["evidence_requirements"], "evidence_requirements", true),
         :ok <- repository(candidate["repository"]) do
      encoded_size(candidate, @max_candidate_bytes)
    end
  end

  defp validate_native_plan(ordered_steps, native_plan) when is_list(native_plan) do
    case normalize_plan(native_plan) do
      {:ok, normalized} ->
        if normalized == Enum.map(ordered_steps, & &1["step"]),
          do: :ok,
          else: {:error, :native_plan_mismatch}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_native_plan(_ordered_steps, _native_plan), do: {:error, :native_plan_missing}

  defp normalize_plan(plan) do
    Enum.reduce_while(plan, {:ok, []}, fn entry, {:ok, acc} ->
      normalized =
        case entry do
          %{"step" => step} when is_binary(step) -> step
          %{step: step} when is_binary(step) -> step
          _ -> nil
        end

      if is_binary(normalized),
        do: {:cont, {:ok, [normalized | acc]}},
        else: {:halt, {:error, :invalid_native_plan}}
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp validate_review(review, candidate, context) do
    with :ok <- digest_string(review["candidate_digest"], "candidate_digest"),
         true <- review["candidate_digest"] == candidate["candidate_digest"] || {:error, :review_candidate_mismatch},
         true <- review["workflow"] == context["workflow"] || {:error, :review_workflow_mismatch},
         true <- review["profile_digest"] == context["profile_digest"] || {:error, :review_profile_mismatch},
         true <- review["verdict"] in ~w(approve revise) || {:error, :invalid_review_verdict},
         :ok <- string_list(review["blocking_findings"], "blocking_findings", true),
         :ok <- string_list(review["advisory_findings"], "advisory_findings", true),
         :ok <- findings_match_verdict(review) do
      encoded_size(review, @max_review_bytes)
    end
  end

  defp findings_match_verdict(%{"verdict" => "approve", "blocking_findings" => []}), do: :ok
  defp findings_match_verdict(%{"verdict" => "revise", "blocking_findings" => [_ | _]}), do: :ok
  defp findings_match_verdict(_review), do: {:error, :review_findings_mismatch}

  defp validate_approval(candidate, review) do
    cond do
      review["verdict"] != "approve" -> {:error, :plan_not_approved}
      review["candidate_digest"] != candidate["candidate_digest"] -> {:error, :review_candidate_mismatch}
      review["profile_digest"] != candidate["profile_digest"] -> {:error, :review_profile_mismatch}
      true -> :ok
    end
  end

  defp validate_existing_execution_plan(workspace, expected, worker_host) do
    case read_execution_plan(workspace, worker_host) do
      {:ok, ^expected} -> {:ok, expected}
      {:ok, existing} -> {:error, {:execution_plan_drift, existing["plan_digest"], expected["plan_digest"]}}
      other -> other
    end
  end

  defp persist_new(path, artifact, max_bytes, exists_error, worker_host) do
    payload = Jason.encode!(artifact, pretty: true) <> "\n"

    if byte_size(payload) > max_bytes do
      {:error, {:artifact_too_large, max_bytes}}
    else
      case WorkspaceArtifact.create_exclusive(path, payload, worker_host) do
        :ok -> {:ok, artifact}
        :exists -> {:error, exists_error}
        {:error, reason} -> {:error, {:artifact_write_failed, path, reason}}
      end
    end
  end

  defp read_json(path, max_bytes, worker_host) do
    case WorkspaceArtifact.read(path, max_bytes, worker_host) do
      :missing -> :missing
      {:ok, payload} -> decode_map(payload)
      {:error, reason} -> {:error, {:artifact_read_failed, path, reason}}
    end
  end

  defp decode_map(payload) do
    case Jason.decode(payload) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, :artifact_not_an_object}
      {:error, reason} -> {:error, {:invalid_artifact_json, reason}}
    end
  end

  defp nonempty_string(value, _field) when is_binary(value) and byte_size(value) in 1..8_192, do: :ok
  defp nonempty_string(_value, field), do: {:error, {:invalid_field, field}}

  defp digest_string(value, field) when is_binary(value) do
    if Regex.match?(~r/^[a-f0-9]{64}$/, value), do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp digest_string(_value, field), do: {:error, {:invalid_field, field}}

  defp workflow(value) when value in ~w(feature fix refactor chore pr), do: :ok
  defp workflow(_value), do: {:error, {:invalid_field, "workflow"}}

  defp verification_profile(value) when value in ~w(Surgical Targeted Full), do: :ok
  defp verification_profile(_value), do: {:error, {:invalid_field, "verification_profile"}}

  defp ordered_steps(steps) when is_list(steps) and length(steps) in 1..@max_items do
    Enum.reduce_while(steps, {:ok, MapSet.new()}, fn step, {:ok, prior_ids} ->
      case validate_ordered_step(step, prior_ids) do
        {:ok, id} -> {:cont, {:ok, MapSet.put(prior_ids, id)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _ids} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp ordered_steps(_steps), do: {:error, {:invalid_field, "ordered_steps"}}

  defp validate_ordered_step(step, prior_ids) when is_map(step) do
    with :ok <- validate_exact_fields(step, @phase_fields),
         :ok <- phase_id(step["id"]),
         true <-
           not MapSet.member?(prior_ids, step["id"]) ||
             {:error, {:duplicate_phase_id, step["id"]}},
         :ok <- nonempty_string(step["step"], "ordered_steps.step"),
         true <- step["status"] in ~w(pending in_progress completed) || {:error, {:invalid_field, "ordered_steps.status"}},
         :ok <- string_list(step["affected_paths"], "ordered_steps.affected_paths", false),
         :ok <- phase_dependencies(step["depends_on"], prior_ids),
         :ok <- verification_profile(step["verification_profile"]),
         :ok <- string_list(step["proof_commands"], "ordered_steps.proof_commands", true),
         :ok <- string_list(step["invariants"], "ordered_steps.invariants", false),
         :ok <- string_list(step["stop_conditions"], "ordered_steps.stop_conditions", false),
         :ok <- string_list(step["evidence_requirements"], "ordered_steps.evidence_requirements", true) do
      {:ok, step["id"]}
    end
  end

  defp validate_ordered_step(_step, _prior_ids), do: {:error, {:invalid_field, "ordered_steps"}}

  defp phase_id(value) when is_binary(value) do
    if Regex.match?(~r/^[a-z][a-z0-9_-]{0,63}$/, value),
      do: :ok,
      else: {:error, {:invalid_field, "ordered_steps.id"}}
  end

  defp phase_id(_value), do: {:error, {:invalid_field, "ordered_steps.id"}}

  defp phase_dependencies(values, prior_ids) do
    with :ok <- string_list(values, "ordered_steps.depends_on", true),
         true <- Enum.uniq(values) == values || {:error, {:invalid_field, "ordered_steps.depends_on"}},
         true <- Enum.all?(values, &MapSet.member?(prior_ids, &1)) || {:error, :phase_dependency_not_prior} do
      :ok
    end
  end

  defp string_list(values, field, allow_empty)
       when is_list(values) and length(values) <= @max_items do
    cond do
      values == [] and not allow_empty -> {:error, {:invalid_field, field}}
      Enum.all?(values, &(is_binary(&1) and byte_size(&1) in 1..8_192)) -> :ok
      true -> {:error, {:invalid_field, field}}
    end
  end

  defp string_list(_values, field, _allow_empty), do: {:error, {:invalid_field, field}}

  defp scope(%{"in" => in_scope, "out" => out_scope} = scope) when map_size(scope) == 2 do
    with :ok <- string_list(in_scope, "scope.in", false) do
      string_list(out_scope, "scope.out", true)
    end
  end

  defp scope(_value), do: {:error, {:invalid_field, "scope"}}

  defp repository(
         %{
           "origin" => origin,
           "base_sha" => base_sha,
           "preactivation_digest" => preactivation_digest
         } = repository
       )
       when map_size(repository) == 3 do
    with :ok <- nonempty_string(origin, "repository.origin"),
         true <-
           (is_binary(base_sha) and Regex.match?(~r/^[a-f0-9]{40,64}$/, base_sha)) ||
             {:error, {:invalid_field, "repository.base_sha"}} do
      digest_string(preactivation_digest, "repository.preactivation_digest")
    end
  end

  defp repository(_value), do: {:error, {:invalid_field, "repository"}}

  defp encoded_size(value, max_bytes) do
    if byte_size(Jason.encode!(value)) <= max_bytes,
      do: :ok,
      else: {:error, {:artifact_too_large, max_bytes}}
  end

  defp canonical_term(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonical_term(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical_term(value) when is_list(value), do: Enum.map(value, &canonical_term/1)
  defp canonical_term(value), do: value

  defp candidate_schema do
    string = %{"type" => "string", "minLength" => 1, "maxLength" => 8192}
    string_array = %{"type" => "array", "maxItems" => @max_items, "items" => string}

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => @candidate_fields,
      "properties" => %{
        "issue_id" => string,
        "issue_identifier" => string,
        "contract_digest" => string,
        "workflow" => %{"type" => "string", "enum" => ~w(feature fix refactor chore pr)},
        "profile_digest" => string,
        "primary_thread_id" => string,
        "ordered_steps" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_items,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => @phase_fields,
            "properties" => %{
              "id" => %{
                "type" => "string",
                "pattern" => "^[a-z][a-z0-9_-]{0,63}$"
              },
              "step" => string,
              "status" => %{"type" => "string", "enum" => ~w(pending in_progress completed)},
              "affected_paths" => Map.put(string_array, "minItems", 1),
              "depends_on" => string_array,
              "verification_profile" => %{"type" => "string", "enum" => ~w(Surgical Targeted Full)},
              "proof_commands" => string_array,
              "invariants" => Map.put(string_array, "minItems", 1),
              "stop_conditions" => Map.put(string_array, "minItems", 1),
              "evidence_requirements" => string_array
            }
          }
        },
        "affected_paths" => Map.put(string_array, "minItems", 1),
        "scope" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["in", "out"],
          "properties" => %{"in" => Map.put(string_array, "minItems", 1), "out" => string_array}
        },
        "execution_context" => string,
        "scale_shape" => string,
        "verification_profile" => %{"type" => "string", "enum" => ~w(Surgical Targeted Full)},
        "proof_commands" => Map.put(string_array, "minItems", 1),
        "risks" => string_array,
        "invariants" => Map.put(string_array, "minItems", 1),
        "rollback" => string,
        "evidence_requirements" => string_array,
        "repository" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["origin", "base_sha", "preactivation_digest"],
          "properties" => %{
            "origin" => string,
            "base_sha" => string,
            "preactivation_digest" => string
          }
        }
      }
    }
  end

  defp review_schema do
    string = %{"type" => "string", "minLength" => 1, "maxLength" => 8192}
    findings = %{"type" => "array", "maxItems" => @max_items, "items" => string}

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => @review_fields,
      "properties" => %{
        "candidate_digest" => string,
        "verdict" => %{"type" => "string", "enum" => ~w(approve revise)},
        "blocking_findings" => findings,
        "advisory_findings" => findings,
        "workflow" => %{"type" => "string", "enum" => ~w(feature fix refactor chore pr)},
        "profile_digest" => string
      }
    }
  end
end
