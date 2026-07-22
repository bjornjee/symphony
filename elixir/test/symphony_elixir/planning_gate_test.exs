defmodule SymphonyElixir.PlanningGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.TaskContract
  alias SymphonyElixir.{PlanningGate, TaskContractFixtures, WorkflowProfile}

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-planning-gate-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    repository = %{
      origin: "git@github.com:acme/repo.git",
      base_sha: String.duplicate("c", 40),
      digest: String.duplicate("d", 64)
    }

    %{workspace: workspace, repository: repository}
  end

  test "classifies one low-risk docs path and one proof command as simple", ctx do
    {issue, contract, profile} = simple_task()

    assert {:ok, classification} =
             PlanningGate.classify(
               ctx.workspace,
               issue,
               contract,
               profile,
               "primary-thread",
               ctx.repository
             )

    assert classification["category"] == "simple"
    assert classification["affected_paths"] == ["docs/guide.md"]
    assert classification["proof_commands"] == ["mix test test/docs_test.exs"]
    assert byte_size(classification["classification_digest"]) == 64
  end

  test "permits low-risk single-path feature, fix, and refactor workflows", ctx do
    Enum.each(
      [
        {"feat: adjust one formatter behavior", "feature"},
        {"fix: correct one formatter edge case", "fix"},
        {"refactor: rename one private formatter helper", "refactor"}
      ],
      fn {title, workflow} ->
        {issue, contract, profile} = simple_task(%{"Notes For Agent" => "Workflow: #{workflow}"}, title)
        workspace = Path.join(ctx.workspace, workflow)

        assert {:ok, %{"category" => "simple", "workflow" => ^workflow}} =
                 PlanningGate.classify(
                   workspace,
                   issue,
                   contract,
                   profile,
                   "primary-thread",
                   ctx.repository
                 )
      end
    )
  end

  test "falls through to full planning unless every simple-task guard passes", ctx do
    cases = [
      %{"Risk" => "medium"},
      %{"Scope" => "In:\n- docs/guide.md\n- README.md\n\nOut:\n- source code"},
      %{"Scope" => "In:\n- ../../outside.md\n\nOut:\n- source code"},
      %{"Acceptance Criteria" => "- [ ] Guide is current.\n- [ ] Links are valid."},
      %{"Verification" => "Run:\n`mix test test/docs_test.exs`\n`mix format --check-formatted`"},
      %{"Notes For Agent" => "Workflow: fix"},
      %{"Goal" => "Change deployment credentials."},
      %{"Context" => "This changes an authorization boundary."},
      %{"Notes For Agent" => "Workflow: chore\nUpdate the release infrastructure."}
    ]

    Enum.each(cases, fn overrides ->
      {issue, contract, profile} = simple_task(overrides)
      workspace = Path.join(ctx.workspace, Integer.to_string(System.unique_integer([:positive])))

      assert {:ok, %{"category" => "planned", "guard_failures" => [_ | _]}} =
               PlanningGate.classify(
                 workspace,
                 issue,
                 contract,
                 profile,
                 "primary-thread",
                 ctx.repository
               )
    end)
  end

  test "explicit full planning directive cannot be bypassed", ctx do
    {issue, contract, profile} =
      simple_task(%{"Notes For Agent" => "Workflow: chore\nPlanning: full"})

    assert {:ok, %{"category" => "planned", "guard_failures" => failures}} =
             PlanningGate.classify(
               ctx.workspace,
               issue,
               contract,
               profile,
               "primary-thread",
               ctx.repository
             )

    assert "full planning was explicitly requested" in failures
  end

  test "classification is immutable and bound to the primary thread", ctx do
    {issue, contract, profile} = simple_task()

    assert {:ok, classification} =
             PlanningGate.classify(
               ctx.workspace,
               issue,
               contract,
               profile,
               "primary-thread",
               ctx.repository
             )

    assert {:ok, ^classification} =
             PlanningGate.classify(
               ctx.workspace,
               issue,
               contract,
               profile,
               "primary-thread",
               ctx.repository
             )

    assert {:error, :task_classification_thread_drift} =
             PlanningGate.classify(
               ctx.workspace,
               issue,
               contract,
               profile,
               "different-thread",
               ctx.repository
             )
  end

  test "rejects malformed, non-object, and tampered classification artifacts", ctx do
    {issue, contract, profile} = simple_task()

    Enum.each(
      [
        {"{", {:invalid_task_classification_json, :any}},
        {"[]", :task_classification_not_an_object}
      ],
      fn {payload, expected} ->
        workspace = Path.join(ctx.workspace, Integer.to_string(System.unique_integer([:positive])))
        path = PlanningGate.artifact_path(workspace)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, payload)

        result =
          PlanningGate.classify(
            workspace,
            issue,
            contract,
            profile,
            "primary-thread",
            ctx.repository
          )

        case expected do
          {:invalid_task_classification_json, :any} ->
            assert {:error, {:invalid_task_classification_json, _reason}} = result

          expected ->
            assert {:error, ^expected} = result
        end
      end
    )

    workspace = Path.join(ctx.workspace, "tampered")

    assert {:ok, classification} =
             PlanningGate.classify(
               workspace,
               issue,
               contract,
               profile,
               "primary-thread",
               ctx.repository
             )

    File.write!(
      PlanningGate.artifact_path(workspace),
      Jason.encode!(Map.put(classification, "category", "planned"))
    )

    assert {:error, :task_classification_digest_mismatch} =
             PlanningGate.classify(
               workspace,
               issue,
               contract,
               profile,
               "primary-thread",
               ctx.repository
             )
  end

  test "fails closed on invalid artifact paths", ctx do
    {issue, contract, profile} = simple_task()
    read_workspace = Path.join(ctx.workspace, "read-error")
    File.mkdir_p!(PlanningGate.artifact_path(read_workspace))

    assert {:error, {:task_classification_read_failed, {:invalid_artifact_type, :directory}}} =
             PlanningGate.classify(
               read_workspace,
               issue,
               contract,
               profile,
               "primary-thread",
               ctx.repository
             )

    write_workspace = Path.join(ctx.workspace, "write-error")
    File.mkdir_p!(write_workspace)
    File.chmod!(write_workspace, 0o500)

    try do
      assert {:error, {:task_classification_write_failed, _reason}} =
               PlanningGate.classify(
                 write_workspace,
                 issue,
                 contract,
                 profile,
                 "primary-thread",
                 ctx.repository
               )
    after
      File.chmod!(write_workspace, 0o700)
    end
  end

  test "invalid contract shapes conservatively require planning", ctx do
    {issue, contract, profile} = simple_task()

    Enum.each(
      [
        put_in(contract.sections["Scope"], nil),
        put_in(contract.sections["Scope"], "not a scope"),
        put_in(contract.sections["Verification"], nil)
      ],
      fn mutated_contract ->
        workspace = Path.join(ctx.workspace, Integer.to_string(System.unique_integer([:positive])))

        assert {:ok, %{"category" => "planned"}} =
                 PlanningGate.classify(
                   workspace,
                   issue,
                   mutated_contract,
                   profile,
                   "primary-thread",
                   ctx.repository
                 )
      end
    )
  end

  defp simple_task(overrides \\ %{}, title \\ "docs: correct guide example") do
    description =
      TaskContractFixtures.valid_description(
        Map.merge(
          %{
            "Goal" => "Correct one documentation example.",
            "Scope" => "In:\n- docs/guide.md\n\nOut:\n- source code",
            "Acceptance Criteria" => "- [ ] Guide example is current.",
            "Verification" => "Run:\n`mix test test/docs_test.exs`",
            "Risk" => "low",
            "Notes For Agent" => "Workflow: chore"
          },
          overrides
        )
      )

    issue = TaskContractFixtures.issue(%{title: title, description: description})
    {:ok, contract} = TaskContract.from_issue(issue)
    {:ok, profile} = WorkflowProfile.select(contract)
    {issue, contract, profile}
  end
end
