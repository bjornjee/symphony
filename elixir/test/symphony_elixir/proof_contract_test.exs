defmodule SymphonyElixir.ProofContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProofContract

  test "validates typed proofs, prior phases, and criterion coverage" do
    phases = [phase("red", [], ["red-proof"]), phase("green", ["red"], ["green-proof"])]
    proofs = [proof("red-proof", "red", "red", "failure", ["criterion-1"]), proof("green-proof", "green", "final", "success", ["criterion-1"])]

    assert :ok = ProofContract.validate(proofs, phases, ["criterion-1"], ["lib/example.ex"])
  end

  test "rejects an unsafe proof command" do
    phases = [phase("final", [], ["final-proof"])]
    base = proof("final-proof", "final", "final", "success", ["criterion-1"])

    assert {:error, {:unsafe_proof_command, "final-proof"}} =
             ProofContract.validate([%{base | "command" => "git push origin HEAD"}], phases, ["criterion-1"], ["lib/example.ex"])
  end

  test "rejects a proof working directory outside the repository" do
    phases = [phase("final", [], ["final-proof"])]
    base = proof("final-proof", "final", "final", "success", ["criterion-1"])

    assert {:error, {:invalid_proof_working_directory, "final-proof"}} =
             ProofContract.validate([%{base | "working_directory" => "../outside"}], phases, ["criterion-1"], ["lib/example.ex"])
  end

  test "rejects an unknown phase proof id" do
    phases = [phase("final", [], ["final-proof"])]
    base = proof("final-proof", "final", "final", "success", ["criterion-1"])

    assert {:error, {:unknown_proof_id, "missing"}} =
             ProofContract.validate([base], [%{hd(phases) | "proof_ids" => ["missing"]}], ["criterion-1"], ["lib/example.ex"])
  end

  test "rejects an uncovered acceptance criterion" do
    phases = [phase("final", [], ["final-proof"])]
    base = proof("final-proof", "final", "final", "success", ["criterion-1"])

    assert {:error, {:uncovered_criterion, "criterion-2"}} =
             ProofContract.validate([base], phases, ["criterion-1", "criterion-2"], ["lib/example.ex"])
  end

  test "rejects a candidate path outside the repository" do
    phases = [phase("final", [], ["final-proof"])]
    base = proof("final-proof", "final", "final", "success", ["criterion-1"])

    assert {:error, :invalid_candidate_paths} =
             ProofContract.validate([base], phases, ["criterion-1"], ["../outside"])
  end

  test "rejects proof criteria outside the Linear contract" do
    phases = [phase("final", [], ["final-proof"])]
    base = proof("final-proof", "final", "final", "success", ["criterion-1"])

    assert {:error, {:invalid_proof_criteria, "final-proof"}} =
             ProofContract.validate([%{base | "criterion_ids" => ["unknown"]}], phases, ["criterion-1"], ["lib/example.ex"])
  end

  test "accepts a candidate directory as phase scope" do
    phases = [phase("one", [], ["one-proof"]), phase("two", ["one"], ["two-proof"])]
    proofs = [proof("one-proof", "one", "phase", "success", []), proof("two-proof", "two", "final", "success", ["criterion-1"])]

    assert :ok = ProofContract.validate(proofs, phases, ["criterion-1"], ["lib"])
  end

  test "rejects a proof referenced by a different phase" do
    phases = [phase("one", [], ["one-proof"]), phase("two", ["one"], ["two-proof"])]
    proofs = [proof("one-proof", "one", "phase", "success", []), proof("two-proof", "two", "final", "success", ["criterion-1"])]

    assert {:error, {:proof_phase_mismatch, "one-proof", "two"}} =
             ProofContract.validate(proofs, [hd(phases), %{List.last(phases) | "proof_ids" => ["one-proof"]}], ["criterion-1"], ["lib"])
  end

  test "rejects direct repository mutation hidden behind git options" do
    phases = [phase("final", [], ["final-proof"])]
    proof = proof("final-proof", "final", "final", "success", ["criterion-1"])

    assert {:error, {:unsafe_proof_command, "final-proof"}} =
             ProofContract.validate([%{proof | "command" => "git -C . commit -am unsafe"}], phases, ["criterion-1"], ["lib/example.ex"])
  end

  test "requires RED for a fix workflow" do
    final_phase = [phase("final", [], ["final-proof"])]
    final = proof("final-proof", "final", "final", "success", ["criterion-1"])

    assert {:error, :fix_red_proof_required} =
             ProofContract.validate([final], final_phase, ["criterion-1"], ["lib/example.ex"], workflow: "fix")
  end

  test "requires RED when a feature declares it required" do
    final_phase = [phase("final", [], ["final-proof"])]
    final = proof("final-proof", "final", "final", "success", ["criterion-1"])

    assert {:error, :feature_red_proof_required} =
             ProofContract.validate([final], final_phase, ["criterion-1"], ["lib/example.ex"],
               workflow: "feature",
               red_policy: "required"
             )
  end

  test "requires a preservation proof for every refactor transformation" do
    final = proof("final-proof", "finish", "final", "success", ["criterion-1"])

    phases = [
      phase("baseline", [], ["baseline-proof"]),
      phase("transform", ["baseline"], ["transform-proof"]),
      phase("finish", ["transform"], ["final-proof"])
    ]

    proofs = [
      proof("baseline-proof", "baseline", "baseline", "success", []),
      proof("transform-proof", "transform", "green", "success", []),
      final
    ]

    assert {:error, :refactor_phase_proof_required} =
             ProofContract.validate(proofs, phases, ["criterion-1"], ["lib/example.ex"], workflow: "refactor")
  end

  defp phase(id, dependencies, proof_ids) do
    %{"id" => id, "depends_on" => dependencies, "proof_ids" => proof_ids, "affected_paths" => ["lib/example.ex"]}
  end

  defp proof(id, phase_id, role, expected_exit, criterion_ids) do
    %{
      "id" => id,
      "phase_id" => phase_id,
      "role" => role,
      "command" => "mix test test/example_test.exs",
      "working_directory" => ".",
      "expected_exit" => expected_exit,
      "timeout_ms" => 60_000,
      "criterion_ids" => criterion_ids
    }
  end
end
