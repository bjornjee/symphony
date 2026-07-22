defmodule SymphonyElixir.PlanningGate do
  @moduledoc """
  Classifies narrowly provable simple tasks before the planning lifecycle.

  The gate is intentionally conservative: any ambiguity routes to the normal
  read-only plan and automated review flow.
  """

  alias SymphonyElixir.Linear.{Issue, TaskContract}
  alias SymphonyElixir.{PlanningArtifact, WorkflowProfile, WorkspaceArtifact}

  @artifact_path Path.join(".symphony", "task-classification.json")
  @max_artifact_bytes 16_384
  @risky_terms ~w(
    auth authorization credential credentials secret secrets permission permissions migration migrations
    schema schemas database databases dependency dependencies lockfile lockfiles deploy deployment release
    concurrency retry retries idempotency cleanup generated ci build workflow workflows infrastructure
  )

  @spec classify(
          Path.t(),
          Issue.t(),
          TaskContract.t(),
          WorkflowProfile.t(),
          String.t(),
          map(),
          String.t() | nil
        ) :: {:ok, map()} | {:error, term()}
  def classify(workspace, issue, contract, profile, thread_id, repository, worker_host \\ nil) do
    expected = classification(issue, contract, profile, thread_id, repository)

    case read(workspace, worker_host) do
      :missing -> persist(workspace, expected, worker_host)
      {:ok, existing} -> validate_existing(existing, expected)
      {:error, _reason} = error -> error
    end
  end

  @spec artifact_path(Path.t()) :: Path.t()
  def artifact_path(workspace), do: Path.join(workspace, @artifact_path)

  defp classification(issue, contract, profile, thread_id, repository) do
    affected_paths = in_scope_paths(contract.sections["Scope"])
    proof_commands = proof_commands(contract.sections["Verification"])
    guard_failures = guard_failures(issue, contract, profile, affected_paths, proof_commands)

    semantic = %{
      "schema_version" => 1,
      "issue_id" => issue.id,
      "issue_identifier" => issue.identifier,
      "contract_digest" => contract.digest,
      "workflow" => profile.name,
      "profile_digest" => profile.digest,
      "primary_thread_id" => thread_id,
      "category" => if(guard_failures == [], do: "simple", else: "planned"),
      "affected_paths" => affected_paths,
      "proof_commands" => proof_commands,
      "guard_failures" => guard_failures,
      "repository" => repository_context(repository)
    }

    Map.put(semantic, "classification_digest", PlanningArtifact.digest(semantic))
  end

  defp guard_failures(issue, contract, profile, affected_paths, proof_commands) do
    []
    |> require(simple_workflow?(contract.title, profile.name), "workflow and title are not eligible for simple execution")
    |> require(String.downcase(String.trim(contract.sections["Risk"])) == "low", "risk is not low")
    |> require(length(contract.acceptance_criteria) == 1, "task does not have exactly one acceptance criterion")
    |> require(length(affected_paths) == 1, "scope does not name exactly one path")
    |> require(length(proof_commands) == 1, "verification does not name exactly one proof command")
    |> require(not Enum.member?(issue.labels, "codex-decompose"), "task is marked for decomposition")
    |> require(not full_planning_requested?(contract), "full planning was explicitly requested")
    |> require(not risky_boundary?(contract), "task text names a risky boundary")
  end

  defp require(failures, true, _failure), do: failures
  defp require(failures, false, failure), do: failures ++ [failure]

  defp simple_workflow?(title, workflow) do
    case Regex.run(~r/^([a-z]+):\s+\S/i, title, capture: :all_but_first) do
      [prefix] ->
        {String.downcase(prefix), workflow} in [
          {"feat", "feature"},
          {"fix", "fix"},
          {"refactor", "refactor"},
          {"docs", "chore"},
          {"chore", "chore"}
        ]

      _other ->
        false
    end
  end

  defp full_planning_requested?(contract) do
    Regex.match?(~r/^Planning:\s*full\s*$/mi, Map.get(contract.sections, "Notes For Agent", ""))
  end

  defp risky_boundary?(contract) do
    text =
      [
        contract.sections["Goal"],
        contract.sections["Context"],
        in_scope_content(contract.sections["Scope"]),
        contract.sections["Acceptance Criteria"],
        contract.sections["Verification"],
        notes_without_routing_directives(contract.sections["Notes For Agent"])
      ]
      |> Enum.join(" ")
      |> String.downcase()

    Enum.any?(@risky_terms, &Regex.match?(Regex.compile!("\\b#{&1}\\b"), text))
  end

  defp notes_without_routing_directives(notes) when is_binary(notes) do
    notes
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^(?:Workflow|Planning):/i, &1))
    |> Enum.join("\n")
  end

  defp notes_without_routing_directives(_notes), do: ""

  defp in_scope_paths(scope) when is_binary(scope) do
    scope
    |> in_scope_content()
    |> String.split("\n")
    |> Enum.flat_map(&scope_path/1)
  end

  defp in_scope_paths(_scope), do: []

  defp in_scope_content(scope) when is_binary(scope) do
    case Regex.run(~r/^In:\s*\n(.*?)(?=^Out:\s*$)/ms, scope, capture: :all_but_first) do
      [content] -> content
      _other -> ""
    end
  end

  defp in_scope_content(_scope), do: ""

  defp scope_path(line) do
    case Regex.run(~r/^\s*[-*+]\s+`?([^`\s,]+)`?\s*$/, line, capture: :all_but_first) do
      [path] -> if safe_repo_path?(path), do: [path], else: []
      _other -> []
    end
  end

  defp safe_repo_path?(path) do
    Path.type(path) == :relative and
      not String.contains?(path, ["\\", "*", "?", "[", "]", "{", "}"]) and
      Enum.all?(Path.split(path), &(&1 not in [".", ".."]))
  end

  defp proof_commands(verification) when is_binary(verification) do
    ~r/`([^`\n]+)`/
    |> Regex.scan(verification, capture: :all_but_first)
    |> Enum.map(fn [command] -> String.trim(command) end)
    |> Enum.reject(&(&1 == ""))
  end

  defp proof_commands(_verification), do: []

  defp repository_context(repository) do
    %{
      "origin" => repository.origin,
      "base_sha" => repository.base_sha,
      "preactivation_digest" => repository.digest
    }
  end

  defp persist(workspace, classification, worker_host) do
    payload = Jason.encode!(classification, pretty: true) <> "\n"

    if byte_size(payload) > @max_artifact_bytes do
      {:error, {:task_classification_too_large, @max_artifact_bytes}}
    else
      case WorkspaceArtifact.create_exclusive(artifact_path(workspace), payload, worker_host) do
        :ok -> {:ok, classification}
        :exists -> read_and_validate(workspace, classification, worker_host)
        {:error, reason} -> {:error, {:task_classification_write_failed, reason}}
      end
    end
  end

  defp read_and_validate(workspace, expected, worker_host) do
    case read(workspace, worker_host) do
      {:ok, existing} -> validate_existing(existing, expected)
      other -> other
    end
  end

  defp read(workspace, worker_host) do
    case WorkspaceArtifact.read(artifact_path(workspace), @max_artifact_bytes, worker_host) do
      :missing -> :missing
      {:ok, payload} -> decode(payload)
      {:error, reason} -> {:error, {:task_classification_read_failed, reason}}
    end
  end

  defp decode(payload) do
    case Jason.decode(payload) do
      {:ok, classification} when is_map(classification) -> {:ok, classification}
      {:ok, _other} -> {:error, :task_classification_not_an_object}
      {:error, reason} -> {:error, {:invalid_task_classification_json, reason}}
    end
  end

  defp validate_existing(existing, expected) do
    cond do
      existing["classification_digest"] !=
          PlanningArtifact.digest(Map.delete(existing, "classification_digest")) ->
        {:error, :task_classification_digest_mismatch}

      existing["primary_thread_id"] != expected["primary_thread_id"] ->
        {:error, :task_classification_thread_drift}

      existing != expected ->
        {:error, :task_classification_drift}

      true ->
        {:ok, existing}
    end
  end
end
