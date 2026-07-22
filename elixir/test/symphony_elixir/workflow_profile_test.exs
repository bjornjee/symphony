defmodule SymphonyElixir.WorkflowProfileTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.TaskContract
  alias SymphonyElixir.TaskContractFixtures
  alias SymphonyElixir.WorkflowProfile

  test "selects an explicit workflow from Notes For Agent" do
    issue =
      TaskContractFixtures.issue(%{
        title: "Repair handoff validation",
        description:
          TaskContractFixtures.valid_description(%{
            "Notes For Agent" => "Keep the change focused.\nWorkflow: fix"
          })
      })

    assert {:ok, profile} = issue |> contract!() |> WorkflowProfile.select()
    assert profile.name == "fix"
    assert profile.version == 1
    assert byte_size(profile.digest) == 64
    assert profile.instructions =~ "Ground the defect"
  end

  test "falls back to the conventional title prefix" do
    issue =
      TaskContractFixtures.issue(%{
        title: "refactor: isolate plan validation",
        description: TaskContractFixtures.valid_description(%{"Notes For Agent" => "Keep scope bounded."})
      })

    assert {:ok, profile} = issue |> contract!() |> WorkflowProfile.select()
    assert profile.name == "refactor"
  end

  test "explicit workflow takes precedence over the title prefix" do
    issue =
      TaskContractFixtures.issue(%{
        title: "fix: update generated documentation",
        description:
          TaskContractFixtures.valid_description(%{
            "Notes For Agent" => "Workflow: chore"
          })
      })

    assert {:ok, profile} = issue |> contract!() |> WorkflowProfile.select()
    assert profile.name == "chore"
  end

  test "rejects multiple workflow directives" do
    issue =
      TaskContractFixtures.issue(%{
        description:
          TaskContractFixtures.valid_description(%{
            "Notes For Agent" => "Workflow: fix\nWorkflow: feature"
          })
      })

    assert {:error, :ambiguous_workflow_profile} =
             issue |> contract!() |> WorkflowProfile.select()
  end

  test "rejects tasks without a deterministic workflow" do
    issue =
      TaskContractFixtures.issue(%{
        title: "Improve handoff validation",
        description: TaskContractFixtures.valid_description(%{"Notes For Agent" => "Keep scope bounded."})
      })

    assert {:error, :workflow_profile_missing} =
             issue |> contract!() |> WorkflowProfile.select()
  end

  test "rejects unsupported explicit workflows" do
    issue =
      TaskContractFixtures.issue(%{
        description:
          TaskContractFixtures.valid_description(%{
            "Notes For Agent" => "Workflow: investigate"
          })
      })

    assert {:error, {:unsupported_workflow_profile, "investigate"}} =
             issue |> contract!() |> WorkflowProfile.select()
  end

  test "profiles carry operational phases, gates, and stop conditions" do
    expected = %{
      "feature" => ["RED decision", "Minimum GREEN", "Final proof"],
      "fix" => ["Ground the defect", "Symptom-matching RED", "Falsifiable root cause"],
      "refactor" => ["Caller and coverage inventory", "Green baseline", "Atomic transformations"],
      "chore" => ["Routing gate", "Validation escalation", "Delivery"],
      "pr" => ["Preflight", "Full branch review", "Final gate"]
    }

    for {name, required_phrases} <- expected do
      assert {:ok, profile} = WorkflowProfile.load(name)
      assert profile.instructions =~ "Phase gate"
      assert profile.instructions =~ "Stop conditions"

      for phrase <- required_phrases do
        assert profile.instructions =~ phrase
      end
    end
  end

  defp contract!(issue) do
    assert {:ok, contract} = TaskContract.from_issue(issue)
    contract
  end
end
