defmodule SymphonyElixir.PlanningArtifactTest do
  use ExUnit.Case

  alias SymphonyElixir.PlanningArtifact

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-planning-artifact-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    context = %{
      "issue_id" => "issue-1",
      "issue_identifier" => "SYM-1",
      "contract_digest" => String.duplicate("a", 64),
      "workflow" => "fix",
      "profile_digest" => String.duplicate("b", 64),
      "primary_thread_id" => "thread-1",
      "repository" => %{
        "origin" => "git@github.com:acme/repo.git",
        "base_sha" => String.duplicate("c", 40),
        "preactivation_digest" => String.duplicate("d", 64)
      }
    }

    candidate =
      Map.merge(context, %{
        "ordered_steps" => [
          phase("reproduce", "Reproduce the defect", "in_progress", [], ["red"]),
          phase(
            "fix",
            "Implement and prove the fix",
            "pending",
            ["reproduce"],
            ["final"]
          )
        ],
        "affected_paths" => ["lib/example.ex", "test/example_test.exs"],
        "scope" => %{"in" => ["validation"], "out" => ["API redesign"]},
        "execution_context" => "request/response; one validation per request",
        "scale_shape" => "bounded by one request payload",
        "verification_profile" => "Targeted",
        "proofs" => [
          proof("red", "reproduce", "red", "failure"),
          proof("final", "fix", "final", "success")
        ],
        "red_policy" => "required",
        "red_waiver_rationale" => nil,
        "risks" => ["shared validation path"],
        "invariants" => ["valid inputs remain accepted"],
        "rollback" => "revert the task commit",
        "evidence_requirements" => ["RED before GREEN"]
      })

    %{workspace: workspace, context: context, candidate: candidate}
  end

  test "candidate tool is strict and excludes mutation tools" do
    assert [%{"name" => "submit_execution_plan", "inputSchema" => schema}] =
             PlanningArtifact.candidate_tool_specs()

    assert schema["additionalProperties"] == false
    assert "ordered_steps" in schema["required"]
  end

  test "validates native plan agreement and persists a candidate exclusively", %{
    workspace: workspace,
    context: context,
    candidate: candidate
  } do
    native_plan = candidate["ordered_steps"]

    assert {:ok, persisted} =
             PlanningArtifact.persist_candidate(workspace, 1, candidate, context, native_plan)

    assert byte_size(persisted["candidate_digest"]) == 64
    assert {:ok, ^persisted} = PlanningArtifact.read_candidate(workspace, 1)

    changed = put_in(candidate, ["rollback"], "something else")

    assert {:error, {:candidate_already_exists, 1}} =
             PlanningArtifact.persist_candidate(workspace, 1, changed, context, native_plan)
  end

  test "allows a read-only phase with no affected paths", %{
    workspace: workspace,
    context: context,
    candidate: candidate
  } do
    candidate = put_in(candidate, ["ordered_steps", Access.at(0), "affected_paths"], [])

    assert {:ok, persisted} =
             PlanningArtifact.persist_candidate(
               workspace,
               1,
               candidate,
               context,
               candidate["ordered_steps"]
             )

    assert get_in(persisted, ["ordered_steps", Access.at(0), "affected_paths"]) == []
  end

  test "rejects a candidate whose ordered steps differ from the final native plan", %{
    workspace: workspace,
    context: context,
    candidate: candidate
  } do
    assert {:error, :native_plan_mismatch} =
             PlanningArtifact.persist_candidate(
               workspace,
               1,
               candidate,
               context,
               [%{"step" => "A different plan", "status" => "pending"}]
             )
  end

  test "review is bound to the exact candidate and profile and sealing requires approval", %{
    workspace: workspace,
    context: context,
    candidate: candidate
  } do
    assert {:ok, persisted_candidate} =
             PlanningArtifact.persist_candidate(
               workspace,
               1,
               candidate,
               context,
               candidate["ordered_steps"]
             )

    review = %{
      "candidate_digest" => persisted_candidate["candidate_digest"],
      "verdict" => "approve",
      "blocking_findings" => [],
      "advisory_findings" => ["Keep the change isolated."],
      "workflow" => context["workflow"],
      "profile_digest" => context["profile_digest"]
    }

    assert {:ok, persisted_review} =
             PlanningArtifact.persist_review(workspace, 1, review, persisted_candidate, context)

    assert {:ok, execution_plan} =
             PlanningArtifact.seal(workspace, persisted_candidate, persisted_review)

    assert execution_plan["candidate_digest"] == persisted_candidate["candidate_digest"]
    assert byte_size(execution_plan["plan_digest"]) == 64
    assert {:ok, ^execution_plan} = PlanningArtifact.read_execution_plan(workspace)
  end

  test "a revision verdict cannot be sealed", %{
    workspace: workspace,
    context: context,
    candidate: candidate
  } do
    assert {:ok, persisted_candidate} =
             PlanningArtifact.persist_candidate(
               workspace,
               1,
               candidate,
               context,
               candidate["ordered_steps"]
             )

    review = %{
      "candidate_digest" => persisted_candidate["candidate_digest"],
      "verdict" => "revise",
      "blocking_findings" => ["Add the RED proof command."],
      "advisory_findings" => [],
      "workflow" => context["workflow"],
      "profile_digest" => context["profile_digest"]
    }

    assert {:ok, persisted_review} =
             PlanningArtifact.persist_review(workspace, 1, review, persisted_candidate, context)

    assert {:error, :plan_not_approved} =
             PlanningArtifact.seal(workspace, persisted_candidate, persisted_review)
  end

  test "sealing is idempotent and rejects semantic drift", %{
    workspace: workspace,
    context: context,
    candidate: candidate
  } do
    assert {:ok, persisted_candidate} =
             PlanningArtifact.persist_candidate(
               workspace,
               1,
               candidate,
               context,
               candidate["ordered_steps"]
             )

    review = %{
      "candidate_digest" => persisted_candidate["candidate_digest"],
      "verdict" => "approve",
      "blocking_findings" => [],
      "advisory_findings" => [],
      "workflow" => context["workflow"],
      "profile_digest" => context["profile_digest"]
    }

    assert {:ok, persisted_review} =
             PlanningArtifact.persist_review(workspace, 1, review, persisted_candidate, context)

    assert {:ok, execution_plan} =
             PlanningArtifact.seal(workspace, persisted_candidate, persisted_review)

    assert {:ok, ^execution_plan} =
             PlanningArtifact.seal(workspace, persisted_candidate, persisted_review)

    changed_candidate =
      persisted_candidate
      |> Map.put("rollback", "revert a different task commit")
      |> Map.put(
        "candidate_digest",
        PlanningArtifact.digest(Map.put(candidate, "rollback", "revert a different task commit"))
      )

    changed_review = %{persisted_review | "candidate_digest" => changed_candidate["candidate_digest"]}

    assert {:error, {:execution_plan_drift, execution_digest, changed_digest}} =
             PlanningArtifact.seal(workspace, changed_candidate, changed_review)

    assert execution_digest == execution_plan["plan_digest"]
    refute changed_digest == execution_digest
  end

  test "rejects missing and malformed native plans and non-object submissions", %{
    workspace: workspace,
    context: context,
    candidate: candidate
  } do
    atom_key_plan = Enum.map(candidate["ordered_steps"], &%{step: &1["step"]})

    assert {:ok, _persisted} =
             PlanningArtifact.persist_candidate(workspace, 1, candidate, context, atom_key_plan)

    for {isolated, submission, native_plan, expected} <- [
          {"missing", candidate, nil, :native_plan_missing},
          {"malformed", candidate, [%{status: "pending"}], :invalid_native_plan},
          {"not-object", [], candidate["ordered_steps"], :artifact_not_an_object}
        ] do
      assert {:error, ^expected} =
               PlanningArtifact.persist_candidate(
                 Path.join(workspace, isolated),
                 1,
                 submission,
                 context,
                 native_plan
               )
    end
  end

  test "distinguishes missing, invalid JSON, and unreadable persisted artifacts", %{
    workspace: workspace
  } do
    assert :missing = PlanningArtifact.read_execution_plan(workspace)

    invalid_json = PlanningArtifact.execution_plan_path(workspace)
    File.mkdir_p!(Path.dirname(invalid_json))
    File.write!(invalid_json, "{")
    assert {:error, {:invalid_artifact_json, _reason}} = PlanningArtifact.read_execution_plan(workspace)

    File.rm!(invalid_json)
    File.mkdir_p!(invalid_json)

    assert {:error, {:artifact_read_failed, ^invalid_json, {:invalid_artifact_type, :directory}}} =
             PlanningArtifact.read_execution_plan(workspace)
  end

  test "rejects malformed candidate fields before writing", %{
    workspace: workspace,
    context: context,
    candidate: candidate
  } do
    malformed = [
      Map.put(candidate, "contract_digest", nil),
      Map.put(candidate, "contract_digest", "bad"),
      Map.put(candidate, "workflow", "unknown"),
      Map.put(candidate, "verification_profile", "Huge"),
      Map.put(candidate, "ordered_steps", []),
      Map.put(candidate, "ordered_steps", [%{"step" => "missing status"}]),
      put_in(candidate, ["ordered_steps", Access.at(0), "id"], nil),
      put_in(candidate, ["ordered_steps", Access.at(0), "stop_conditions"], []),
      put_in(candidate, ["ordered_steps", Access.at(1), "depends_on"], ["missing-phase"]),
      Map.put(candidate, "affected_paths", []),
      Map.put(candidate, "affected_paths", nil),
      Map.put(candidate, "proofs", []),
      Map.put(candidate, "risks", [1]),
      Map.put(candidate, "rollback", ""),
      Map.put(candidate, "scope", %{"in" => [], "out" => []}),
      Map.put(candidate, "scope", nil),
      Map.put(candidate, "repository", %{"origin" => "x"})
    ]

    Enum.with_index(malformed, 1)
    |> Enum.each(fn {invalid, revision} ->
      workspace = Path.join(workspace, "invalid-#{revision}")

      assert {:error, _reason} =
               PlanningArtifact.persist_candidate(
                 workspace,
                 1,
                 invalid,
                 context,
                 candidate["ordered_steps"]
               )
    end)

    assert {:error, {:invalid_artifact_fields, _expected, _actual}} =
             PlanningArtifact.persist_candidate(
               workspace,
               1,
               Map.put(candidate, "extra", true),
               context,
               candidate["ordered_steps"]
             )
  end

  test "rejects duplicate phase ids and dependencies on later phases", %{
    workspace: workspace,
    context: context,
    candidate: candidate
  } do
    duplicate_id = put_in(candidate, ["ordered_steps", Access.at(1), "id"], "reproduce")
    forward_dependency = put_in(candidate, ["ordered_steps", Access.at(0), "depends_on"], ["fix"])

    for {name, invalid} <- [{"duplicate", duplicate_id}, {"forward", forward_dependency}] do
      assert {:error, _reason} =
               PlanningArtifact.persist_candidate(
                 Path.join(workspace, name),
                 1,
                 invalid,
                 context,
                 invalid["ordered_steps"]
               )
    end
  end

  test "rejects malformed reviews and malformed persisted JSON", %{
    workspace: workspace,
    context: context,
    candidate: candidate
  } do
    assert {:ok, persisted_candidate} =
             PlanningArtifact.persist_candidate(
               workspace,
               1,
               candidate,
               context,
               candidate["ordered_steps"]
             )

    base_review = %{
      "candidate_digest" => persisted_candidate["candidate_digest"],
      "verdict" => "approve",
      "blocking_findings" => [],
      "advisory_findings" => [],
      "workflow" => context["workflow"],
      "profile_digest" => context["profile_digest"]
    }

    for invalid <- [
          %{base_review | "candidate_digest" => String.duplicate("0", 64)},
          %{base_review | "profile_digest" => String.duplicate("0", 64)},
          %{base_review | "verdict" => "revise"},
          %{base_review | "blocking_findings" => ["approval cannot block"]}
        ] do
      isolated = Path.join(workspace, PlanningArtifact.digest(invalid))

      assert {:error, _reason} =
               PlanningArtifact.persist_review(
                 isolated,
                 1,
                 invalid,
                 persisted_candidate,
                 context
               )
    end

    malformed_path = PlanningArtifact.review_path(workspace, 1)
    File.write!(malformed_path, "[]")
    assert {:error, :artifact_not_an_object} = PlanningArtifact.read_review(workspace, 1)
  end

  defp phase(id, step, status, depends_on, proof_ids) do
    %{
      "id" => id,
      "step" => step,
      "status" => status,
      "affected_paths" => ["lib/example.ex", "test/example_test.exs"],
      "depends_on" => depends_on,
      "verification_profile" => "Targeted",
      "proof_ids" => proof_ids,
      "criterion_ids" => [],
      "invariants" => ["valid inputs remain accepted"],
      "stop_conditions" => ["Stop if the observed failure differs from the reported defect"],
      "evidence_requirements" => ["Record the engine-observed command event"]
    }
  end

  defp proof(id, phase_id, role, expected_exit) do
    %{
      "id" => id,
      "phase_id" => phase_id,
      "role" => role,
      "command" => "mix test test/example_test.exs",
      "working_directory" => ".",
      "expected_exit" => expected_exit,
      "timeout_ms" => 60_000,
      "criterion_ids" => []
    }
  end
end
