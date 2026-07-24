defmodule SymphonyElixir.VerificationProfileTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.VerificationProfile

  test "keeps a one-path Surgical change Surgical" do
    assert {:ok, %{selected: "Surgical", effective: "Surgical", escalated: false}} =
             VerificationProfile.resolve(plan("Surgical", ["README.md"]), ["README.md"])
  end

  test "escalates a multi-path approved Surgical change to Targeted" do
    assert {:ok,
            %{
              selected: "Surgical",
              effective: "Targeted",
              escalated: true,
              reason: "expanded approved diff"
            }} =
             VerificationProfile.resolve(
               plan("Surgical", ["README.md", "docs/setup.md"]),
               ["README.md", "docs/setup.md"]
             )
  end

  test "escalates unauthorized scope to Full and fails closed" do
    assert {:error,
            {:verification_profile_escalation_required,
             %{
               selected: "Surgical",
               effective: "Full",
               reason: "changed path outside approved scope",
               changed_paths: ["README.md", "lib/runtime.ex"]
             }}} =
             VerificationProfile.resolve(plan("Surgical", ["README.md"]), [
               "README.md",
               "lib/runtime.ex"
             ])
  end

  test "never lowers a Full profile" do
    assert {:ok, %{selected: "Full", effective: "Full", escalated: false}} =
             VerificationProfile.resolve(plan("Full", ["lib/runtime.ex"]), ["lib/runtime.ex"])
  end

  test "uncertain profile data escalates to Full" do
    assert {:ok,
            %{
              selected: "Uncertain",
              effective: "Full",
              escalated: true,
              reason: "verification profile is uncertain"
            }} =
             VerificationProfile.resolve(
               %{"execution_mode" => "simple", "affected_paths" => ["lib/runtime.ex"]},
               ["lib/runtime.ex"]
             )
  end

  defp plan(profile, affected_paths) do
    %{
      "execution_mode" => "simple",
      "verification_profile" => profile,
      "affected_paths" => affected_paths
    }
  end
end
