defmodule SymphonyElixir.CreateLinearIssueSkillTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @skill_path Path.join(@repo_root, ".codex/skills/create-linear-issue/SKILL.md")
  @metadata_path Path.join(@repo_root, ".codex/skills/create-linear-issue/agents/openai.yaml")
  @linear_skill_path Path.join(@repo_root, ".codex/skills/linear/SKILL.md")

  test "valid creation uses the exact Codex Agent Task v1 section order and shape" do
    template = skill() |> fenced_block("md")

    assert_ordered(template, [
      "## Goal",
      "## Context",
      "## Scope",
      "## Acceptance Criteria",
      "## Verification",
      "## Risk",
      "## Notes For Agent"
    ])

    assert template =~ "In:\n- "
    assert template =~ "Out:\n- "
    assert template =~ "- [ ] "
  end

  test "rejects malformed task templates before issue creation" do
    content = skill()

    assert content =~ "Reject empty, duplicate, out-of-order, placeholder, or malformed sections"
    assert content =~ "before `issueCreate`"
  end

  test "resolves every target uniquely before mutation" do
    content = skill()

    for target <- ["team", "project", "state", "labels"] do
      assert content =~ target
    end

    assert content =~ "zero matches"
    assert content =~ "multiple matches"
    assert content =~ "materially ambiguous"
    assert content =~ "before any mutation"
  end

  test "treats an explicit create request as authority for one issue" do
    content = skill()

    assert content =~ "An explicit create request is sufficient mutation authority"
    assert content =~ "one resulting issue"
    assert content =~ "`issueCreate`"
    assert content =~ "top-level `errors`"
  end

  test "reconciles an ambiguous create response before retry" do
    content = skill()

    assert content =~ "ambiguous create response"
    assert content =~ "read-only reconciliation"
    assert content =~ "before retry"
    assert content =~ "Do not blindly retry"
    assert content =~ "zero-result read cannot prove absence"
  end

  test "reads the created issue back and verifies every requested field" do
    content = skill()

    assert content =~ "Read the issue back"

    for field <- ["title", "description", "team", "project", "state", "labels"] do
      assert content =~ field
    end
  end

  test "adds codex-ready only under separate explicit dispatch authority" do
    content = skill()

    assert content =~ "`codex-ready` is never implicit"
    assert content =~ "dispatch was explicitly requested"
    assert content =~ "contract validates"
    assert content =~ "separate `issueUpdate`"
  end

  test "reuses the repository Linear skill without plugin metadata" do
    content = skill()
    metadata = File.read!(@metadata_path)

    assert content =~ ".codex/skills/linear/SKILL.md"
    assert content =~ "`linear_graphql`"
    refute content =~ "plugin"
    refute metadata =~ "dependencies:"
    refute metadata =~ "plugin"
  end

  test "keeps raw issue-creation GraphQL mechanics in the Linear skill" do
    content = File.read!(@linear_skill_path)

    for operation <- [
          "ResolveIssueCreationTargets",
          "CreateIssue",
          "ReconcileIssueCreate",
          "IssueCreationReadback",
          "AddIssueLabels"
        ] do
      assert content =~ operation
    end
  end

  defp skill, do: File.read!(@skill_path)

  defp fenced_block(content, language) do
    [_, block | _] = String.split(content, "```#{language}\n", parts: 2) ++ [""]
    block |> String.split("```", parts: 2) |> hd()
  end

  defp assert_ordered(content, values) do
    positions = Enum.map(values, &match_position!(content, &1))
    assert positions == Enum.sort(positions)
  end

  defp match_position!(content, value) do
    case :binary.match(content, value) do
      {position, _length} -> position
      :nomatch -> flunk("expected #{inspect(value)} in the task template")
    end
  end
end
