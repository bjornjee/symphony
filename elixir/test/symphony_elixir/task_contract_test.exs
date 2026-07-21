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
end
