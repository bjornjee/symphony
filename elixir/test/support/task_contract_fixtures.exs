defmodule SymphonyElixir.TaskContractFixtures do
  alias SymphonyElixir.Linear.Issue

  def valid_description(overrides \\ %{}) do
    sections =
      Map.merge(
        %{
          "Goal" => "Deliver one concrete outcome.",
          "Context" => "The repository and prior issue provide the required context.",
          "Scope" => "In:\n- lib and test files\n\nOut:\n- unrelated cleanup",
          "Acceptance Criteria" => "- [ ] The result is observable.\n- [ ] The failure path is covered.",
          "Verification" => "Run:\n`mix test`",
          "Risk" => "medium",
          "Notes For Agent" => "Keep the change focused."
        },
        overrides
      )

    ["Goal", "Context", "Scope", "Acceptance Criteria", "Verification", "Risk", "Notes For Agent"]
    |> Enum.map_join("\n\n", fn heading -> "## #{heading}\n#{Map.fetch!(sections, heading)}" end)
  end

  def issue(overrides \\ %{}) do
    defaults = %{
      id: "issue-1",
      identifier: "PIN-14",
      title: "Validate and pin approved Linear task revisions",
      description: valid_description(),
      state: "Todo",
      labels: ["codex-ready"],
      updated_at: ~U[2026-07-21 03:00:00Z]
    }

    struct!(Issue, Map.merge(defaults, overrides))
  end
end
