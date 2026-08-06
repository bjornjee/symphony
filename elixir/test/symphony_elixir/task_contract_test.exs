defmodule SymphonyElixir.TaskContractTest do
  use ExUnit.Case, async: true

  import SymphonyElixir.TaskContractFixtures
  alias SymphonyElixir.Linear.TaskContract

  test "valid v1 contract produces a versioned SHA-256 digest" do
    assert {:ok, contract} = TaskContract.from_issue(issue())
    assert contract.version == 1
    assert contract.digest =~ ~r/^[0-9a-f]{64}$/

    assert Enum.map(contract.acceptance_criteria, & &1.text) == [
             "The result is observable.",
             "The failure path is covered."
           ]

    assert Enum.all?(contract.acceptance_criteria, &Regex.match?(~r/^ac-[0-9a-f]{64}$/, &1.id))
  end

  test "line-ending and trailing-whitespace differences preserve the digest" do
    original = issue()

    reformatted =
      issue(%{
        description:
          original.description
          |> String.replace("\n", "  \r\n")
          |> Kernel.<>("\r\n")
      })

    assert {:ok, first} = TaskContract.from_issue(original)
    assert {:ok, second} = TaskContract.from_issue(reformatted)
    assert first.digest == second.digest
  end

  test "title changes produce a different digest" do
    assert {:ok, first} = TaskContract.from_issue(issue())
    assert {:ok, second} = TaskContract.from_issue(issue(%{title: "A changed approved goal"}))
    refute first.digest == second.digest
  end

  test "missing required section fails with an actionable error" do
    description = String.replace(valid_description(), ~r/\n\n## Verification\n.*?(?=\n\n## Risk)/s, "")

    assert {:error, errors} = TaskContract.from_issue(issue(%{description: description}))
    assert "Missing required heading: ## Verification" in errors
  end

  test "duplicate heading fails with an actionable error" do
    description = valid_description() <> "\n\n## Goal\nA second goal."

    assert {:error, errors} = TaskContract.from_issue(issue(%{description: description}))
    assert "Duplicate heading: ## Goal" in errors
  end

  test "out-of-order headings fail with an actionable error" do
    description =
      valid_description()
      |> String.replace("## Goal\n", "## Temporary\n")
      |> String.replace("## Context\n", "## Goal\n")
      |> String.replace("## Temporary\n", "## Context\n")

    assert {:error, errors} = TaskContract.from_issue(issue(%{description: description}))
    assert "Required headings are out of order." in errors
  end

  test "empty section fails with an actionable error" do
    description = valid_description(%{"Context" => "   "})

    assert {:error, errors} = TaskContract.from_issue(issue(%{description: description}))
    assert "Section cannot be empty: ## Context" in errors
  end

  test "placeholder content fails with an actionable error" do
    description = valid_description(%{"Goal" => "<one concrete outcome>"})

    assert {:error, errors} = TaskContract.from_issue(issue(%{description: description}))
    assert "Section contains placeholder content: ## Goal" in errors
  end

  test "scope requires bounded In and Out lists" do
    description = valid_description(%{"Scope" => "In:\n- lib files"})

    assert {:error, errors} = TaskContract.from_issue(issue(%{description: description}))
    assert "Section must include Out with at least one bullet: ## Scope" in errors
  end

  test "scope does not count an Out bullet as an In bullet" do
    description = valid_description(%{"Scope" => "In:\n\nOut:\n- unrelated cleanup"})

    assert {:error, errors} = TaskContract.from_issue(issue(%{description: description}))
    assert "Section must include In with at least one bullet: ## Scope" in errors
  end

  test "scope accepts Linear-normalized markdown lists" do
    description =
      valid_description(%{
        "Scope" => "In:\n\n* LIVE_E2E_RESULT.txt\n\nOut:\n\n* repository source changes"
      })

    assert {:ok, _contract} = TaskContract.from_issue(issue(%{description: description}))
  end

  test "acceptance criteria require checkboxes" do
    description = valid_description(%{"Acceptance Criteria" => "- The result is observable."})

    assert {:error, errors} = TaskContract.from_issue(issue(%{description: description}))
    assert "Section must include at least one checkbox: ## Acceptance Criteria" in errors
  end

  test "acceptance criteria reject non-checkbox list items" do
    description =
      valid_description(%{
        "Acceptance Criteria" => "- [ ] The result is observable.\n- This item is malformed."
      })

    assert {:error, errors} = TaskContract.from_issue(issue(%{description: description}))
    assert "Every acceptance criterion must be a checkbox item." in errors
  end

  test "acceptance criterion identities are stable across checkbox state changes" do
    original = issue()

    checked =
      issue(%{
        description: String.replace(original.description, "- [ ] The result is observable.", "- [x] The result is observable.")
      })

    assert {:ok, first} = TaskContract.from_issue(original)
    assert {:ok, second} = TaskContract.from_issue(checked)

    assert Enum.map(first.acceptance_criteria, & &1.id) == Enum.map(second.acceptance_criteria, & &1.id)
  end

  test "duplicate acceptance criteria are rejected" do
    description =
      valid_description(%{
        "Acceptance Criteria" => "- [ ] The result is observable.\n- [x] The result is observable."
      })

    assert {:error, errors} = TaskContract.from_issue(issue(%{description: description}))
    assert "Acceptance criteria must be unique." in errors
  end

  test "acceptance criteria are bounded per issue" do
    criteria = Enum.map_join(1..101, "\n", &"- [ ] Observable result #{&1}.")
    description = valid_description(%{"Acceptance Criteria" => criteria})

    assert {:error, errors} = TaskContract.from_issue(issue(%{description: description}))
    assert "Acceptance Criteria cannot contain more than 100 items." in errors
  end

  test "risk accepts only low medium or high" do
    description = valid_description(%{"Risk" => "urgent"})

    assert {:error, errors} = TaskContract.from_issue(issue(%{description: description}))
    assert "Risk must be one of: low, medium, high" in errors
  end

  test "headings inside fenced code blocks are ignored" do
    description = valid_description(%{"Context" => "Example:\n```md\n## Goal\nnot a duplicate\n```"})

    assert {:ok, _contract} = TaskContract.from_issue(issue(%{description: description}))
  end

  describe "Team Mode" do
    test "parses a trusted bounded repository contract" do
      team_issue =
        issue(%{
          labels: ["codex-ready", "codex-team"],
          description: valid_description() <> "\n\n## Team\n" <> valid_team_yaml()
        })

      assert {:ok, contract} =
               TaskContract.from_issue(team_issue,
                 team_repository_registry: team_repository_registry()
               )

      assert contract.team.request_id == "PIN-14"
      assert contract.team.validation_goal == "The changes work together."
      assert contract.team.invariants == ["Infrastructure lands first."]

      assert Enum.map(contract.team.repositories, &{&1.agent_id, &1.workflow}) == [
               {"repo:application", "application"},
               {"repo:infrastructure", "infrastructure"}
             ]

      assert hd(contract.team.repositories).trusted_config ==
               team_repository_registry()["application"]
    end

    test "requires the label and section to appear together" do
      section_only = issue(%{description: valid_description() <> "\n\n## Team\n" <> valid_team_yaml()})
      label_only = issue(%{labels: ["codex-ready", "codex-team"]})

      assert {:error, section_errors} = TaskContract.from_issue(section_only)
      assert "## Team requires the codex-team label." in section_errors

      assert {:error, label_errors} = TaskContract.from_issue(label_only)
      assert "The codex-team label requires a ## Team section." in label_errors
    end

    test "rejects unknown and duplicate workflows" do
      unknown = String.replace(valid_team_yaml(), "workflow: application", "workflow: unknown")

      duplicate =
        String.replace(valid_team_yaml(), "workflow: infrastructure", "workflow: application")

      assert {:error, unknown_errors} =
               TaskContract.from_issue(team_issue(unknown),
                 team_repository_registry: team_repository_registry()
               )

      assert "Unknown Team workflow: unknown" in unknown_errors

      assert {:error, duplicate_errors} =
               TaskContract.from_issue(team_issue(duplicate),
                 team_repository_registry: team_repository_registry()
               )

      assert "Team repositories must use unique workflows." in duplicate_errors
    end

    test "rejects untrusted repository configuration and empty required fields" do
      injected =
        valid_team_yaml()
        |> String.replace("    change: Add API behavior.", "    url: https://example.invalid/repo.git\n    change: ''")
        |> String.replace("validation_goal: The changes work together.", "validation_goal: ''")
        |> String.replace("invariants:\n  - Infrastructure lands first.", "invariants: []")

      assert {:error, errors} =
               TaskContract.from_issue(team_issue(injected),
                 team_repository_registry: team_repository_registry()
               )

      assert "Team repository application contains unsupported keys: url" in errors
      assert "Team repository application change must be non-empty." in errors
      assert "Team validation_goal must be non-empty." in errors
      assert "Team invariants must contain at least one non-empty item." in errors
    end

    test "requires two to eight repositories and non-empty acceptance and verification lists" do
      one_repository =
        """
        repositories:
          - workflow: application
            change: Add API behavior.
            acceptance: []
            verification: []
        validation_goal: The changes work together.
        invariants:
          - The API remains compatible.
        """

      assert {:error, errors} =
               TaskContract.from_issue(team_issue(one_repository),
                 team_repository_registry: team_repository_registry()
               )

      assert "Team mode requires between 2 and 8 repositories." in errors
      assert "Team repository application acceptance must contain at least one non-empty item." in errors
      assert "Team repository application verification must contain at least one non-empty item." in errors
    end

    test "fails closed on malformed YAML shapes and invalid trusted registry entries" do
      assert {:error, ["Team YAML is invalid."]} =
               TaskContract.from_issue(team_issue("["),
                 team_repository_registry: team_repository_registry()
               )

      assert {:error, ["Team YAML must decode to a map."]} =
               TaskContract.from_issue(team_issue("[]"),
                 team_repository_registry: team_repository_registry()
               )

      invalid_shapes = """
      repositories:
        - not-a-map
        - workflow: ''
          change: 42
          acceptance: not-a-list
          verification:
            - ''
      validation_goal: Goal
      invariants:
        - invariant
      """

      assert {:error, shape_errors} =
               TaskContract.from_issue(team_issue(invalid_shapes),
                 team_repository_registry: team_repository_registry()
               )

      assert "Team repository at index 1 must be a map." in shape_errors
      assert "Team repository at index 2 workflow must be non-empty." in shape_errors
      assert "Team repository at index 2 change must be non-empty." in shape_errors
      assert "Team repository at index 2 acceptance must contain at least one non-empty item." in shape_errors
      assert "Team repository at index 2 verification must contain at least one non-empty item." in shape_errors

      invalid_registry = Map.put(team_repository_registry(), "application", "not-a-config-map")

      assert {:error, registry_errors} =
               TaskContract.from_issue(team_issue(valid_team_yaml()),
                 team_repository_registry: invalid_registry
               )

      assert "Invalid trusted Team workflow: application" in registry_errors
    end
  end

  defp team_issue(team_yaml) do
    issue(%{
      labels: ["codex-ready", "codex-team"],
      description: valid_description() <> "\n\n## Team\n" <> team_yaml
    })
  end

  defp valid_team_yaml do
    """
    repositories:
      - workflow: application
        change: Add API behavior.
        acceptance:
          - Existing callers remain compatible.
        verification:
          - mix test
      - workflow: infrastructure
        change: Deploy supporting configuration.
        acceptance:
          - The application can use the configuration.
        verification:
          - terraform validate
    validation_goal: The changes work together.
    invariants:
      - Infrastructure lands first.
    """
  end

  defp team_repository_registry do
    %{
      "application" => %{
        "workspace" => %{"root" => "/workspaces/application"},
        "hooks" => %{"after_create" => "git clone app ."}
      },
      "infrastructure" => %{
        "workspace" => %{"root" => "/workspaces/infrastructure"},
        "hooks" => %{"after_create" => "git clone infra ."}
      }
    }
  end
end
