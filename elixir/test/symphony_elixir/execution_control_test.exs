defmodule SymphonyElixir.ExecutionControlTest do
  use ExUnit.Case

  alias SymphonyElixir.{ExecutionControl, ExecutionLedger, RepositoryFingerprint}

  setup do
    root = Path.join(System.tmp_dir!(), "execution-control-#{System.os_time(:nanosecond)}")
    workspace = Path.join(root, "repo")
    ledger = Path.join(root, "ledger")
    File.mkdir_p!(workspace)
    System.cmd("git", ["init", "-q", workspace])
    System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", workspace, "config", "user.name", "Test"])
    System.cmd("git", ["-C", workspace, "remote", "add", "origin", "git@example.com:repo.git"])
    File.write!(Path.join(workspace, "README.md"), "base\n")
    System.cmd("git", ["-C", workspace, "add", "README.md"])
    System.cmd("git", ["-C", workspace, "commit", "-qm", "chore: base"])
    Application.put_env(:symphony_elixir, :execution_state_root, ledger)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :execution_state_root)
      File.rm_rf(root)
    end)

    {:ok, state} = RepositoryFingerprint.capture(workspace)

    plan = %{
      "plan_digest" => String.duplicate("a", 64),
      "instruction_digest" => String.duplicate("b", 64),
      "profile_digest" => String.duplicate("c", 64),
      "workflow" => "fix",
      "issue_id" => "issue-1",
      "candidate" => %{
        "repository" => %{"origin" => state.origin, "base_sha" => state.base_sha},
        "affected_paths" => ["README.md"],
        "ordered_steps" => [
          %{"id" => "reproduce", "depends_on" => [], "affected_paths" => ["README.md"], "proof_ids" => ["red"]},
          %{"id" => "fix", "depends_on" => ["reproduce"], "affected_paths" => ["README.md"], "proof_ids" => ["green"]}
        ],
        "proofs" => [
          proof("red", "reproduce", "red", "failure", "exit 2"),
          proof("green", "fix", "green", "success", "test -f README.md")
        ]
      }
    }

    key = ExecutionLedger.key(state.origin, "issue-1", plan["plan_digest"])
    %{workspace: workspace, plan: plan, key: key}
  end

  test "runs exact planned proofs and requires diagnosis before fix GREEN", ctx do
    assert {:ok, red} = ExecutionControl.run_plan_proof(ctx.plan, ctx.key, ctx.workspace, "reproduce", "red")
    assert red["passed"]

    assert {:error, :fix_diagnosis_required} =
             ExecutionControl.run_plan_proof(ctx.plan, ctx.key, ctx.workspace, "fix", "green")

    diagnosis = %{
      "claim" => "The test exits because README.md:1 contains base.",
      "path" => "README.md",
      "line_start" => 1,
      "line_end" => 1,
      "evidence_summary" => "RED exited 2",
      "red_proof_id" => "red"
    }

    assert {:ok, _receipt} = ExecutionControl.submit_fix_diagnosis(ctx.plan, ctx.key, diagnosis)
    assert {:ok, green} = ExecutionControl.run_plan_proof(ctx.plan, ctx.key, ctx.workspace, "fix", "green")
    assert green["passed"]
  end

  test "limits every proof to three attempts", ctx do
    assert {:ok, _} = ExecutionControl.run_plan_proof(ctx.plan, ctx.key, ctx.workspace, "reproduce", "red")
    assert {:ok, _} = ExecutionControl.run_plan_proof(ctx.plan, ctx.key, ctx.workspace, "reproduce", "red")
    assert {:ok, _} = ExecutionControl.run_plan_proof(ctx.plan, ctx.key, ctx.workspace, "reproduce", "red")
    assert {:error, :proof_attempts_exhausted} = ExecutionControl.run_plan_proof(ctx.plan, ctx.key, ctx.workspace, "reproduce", "red")
  end

  test "rejects unsupported tools, unknown proofs, and premature phases", ctx do
    assert {:error, {:unsupported_execution_tool, "unknown"}} =
             ExecutionControl.execute_tool(
               ctx.plan,
               ctx.key,
               ctx.workspace,
               "unknown",
               %{},
               []
             )

    assert {:error, :unknown_phase_proof} =
             ExecutionControl.run_plan_proof(
               ctx.plan,
               ctx.key,
               ctx.workspace,
               "reproduce",
               "missing"
             )

    assert {:error, {:phase_dependency_incomplete, "reproduce"}} =
             ExecutionControl.complete_execution_phase(
               ctx.plan,
               ctx.key,
               ctx.workspace,
               "fix"
             )

    assert {:error, {:execution_phase_incomplete, "reproduce"}} =
             ExecutionControl.delivery_state(ctx.plan, ctx.key, ctx.workspace)

    assert {:error, :diagnosis_not_allowed} =
             ExecutionControl.submit_fix_diagnosis(
               Map.put(ctx.plan, "workflow", "chore"),
               ctx.key,
               %{}
             )
  end

  test "feature required RED cannot be waived during execution", ctx do
    plan = ctx.plan |> Map.put("workflow", "feature") |> put_in(["candidate", "red_policy"], "required")

    assert {:error, {:red_proof_required, "red"}} =
             ExecutionControl.run_plan_proof(plan, ctx.key, ctx.workspace, "fix", "green")

    assert {:ok, %{"passed" => true}} =
             ExecutionControl.run_plan_proof(plan, ctx.key, ctx.workspace, "reproduce", "red")

    assert {:ok, %{"passed" => true}} =
             ExecutionControl.run_plan_proof(plan, ctx.key, ctx.workspace, "fix", "green")
  end

  test "refactor transformation proof requires a clean green baseline", ctx do
    plan = %{
      ctx.plan
      | "workflow" => "refactor",
        "candidate" => %{
          ctx.plan["candidate"]
          | "proofs" => [
              proof("baseline", "reproduce", "baseline", "success", "test -f README.md"),
              proof("preserve", "fix", "phase", "success", "test -f README.md")
            ],
            "ordered_steps" => [
              %{
                "id" => "reproduce",
                "depends_on" => [],
                "affected_paths" => ["README.md"],
                "proof_ids" => ["baseline"]
              },
              %{
                "id" => "fix",
                "depends_on" => ["reproduce"],
                "affected_paths" => ["README.md"],
                "proof_ids" => ["preserve"]
              }
            ]
        }
    }

    assert {:error, {:baseline_proof_required, "baseline"}} =
             ExecutionControl.run_plan_proof(plan, ctx.key, ctx.workspace, "fix", "preserve")

    assert {:ok, %{"passed" => true}} =
             ExecutionControl.run_plan_proof(plan, ctx.key, ctx.workspace, "reproduce", "baseline")

    assert {:ok, %{"passed" => true}} =
             ExecutionControl.run_plan_proof(plan, ctx.key, ctx.workspace, "fix", "preserve")
  end

  test "persists idempotent ordered phase receipts", ctx do
    assert {:ok, _red} =
             ExecutionControl.run_plan_proof(ctx.plan, ctx.key, ctx.workspace, "reproduce", "red")

    assert {:ok, red_phase} =
             ExecutionControl.complete_execution_phase(
               ctx.plan,
               ctx.key,
               ctx.workspace,
               "reproduce"
             )

    assert {:ok, ^red_phase} =
             ExecutionControl.complete_execution_phase(
               ctx.plan,
               ctx.key,
               ctx.workspace,
               "reproduce"
             )

    diagnosis = %{
      "claim" => "README.md:1 produces the symptom because it contains base.",
      "path" => "README.md",
      "line_start" => 1,
      "line_end" => 1,
      "evidence_summary" => "The approved RED exited with status 2.",
      "red_proof_id" => "red"
    }

    assert {:ok, _} = ExecutionControl.submit_fix_diagnosis(ctx.plan, ctx.key, diagnosis)
    assert {:ok, _green} = ExecutionControl.run_plan_proof(ctx.plan, ctx.key, ctx.workspace, "fix", "green")
    assert {:ok, _green_phase} = ExecutionControl.complete_execution_phase(ctx.plan, ctx.key, ctx.workspace, "fix")
  end

  test "rejects phase and delivery changes outside approved cumulative scope", ctx do
    assert {:ok, _red} = ExecutionControl.run_plan_proof(ctx.plan, ctx.key, ctx.workspace, "reproduce", "red")
    assert {:ok, _} = ExecutionControl.complete_execution_phase(ctx.plan, ctx.key, ctx.workspace, "reproduce")

    diagnosis = %{
      "claim" => "README.md:1 produces the symptom because it contains base.",
      "path" => "README.md",
      "line_start" => 1,
      "line_end" => 1,
      "evidence_summary" => "The approved RED exited with status 2.",
      "red_proof_id" => "red"
    }

    assert {:ok, _} = ExecutionControl.submit_fix_diagnosis(ctx.plan, ctx.key, diagnosis)
    File.write!(Path.join(ctx.workspace, "OUTSIDE.md"), "unapproved\n")
    assert {:ok, _green} = ExecutionControl.run_plan_proof(ctx.plan, ctx.key, ctx.workspace, "fix", "green")

    assert {:error, {:changed_path_outside_phase_scope, "OUTSIDE.md"}} =
             ExecutionControl.complete_execution_phase(ctx.plan, ctx.key, ctx.workspace, "fix")
  end

  test "final proof and phase receipts become stale after later edits or commits", ctx do
    {base, 0} = System.cmd("git", ["-C", ctx.workspace, "rev-parse", "HEAD"])
    System.cmd("git", ["-C", ctx.workspace, "switch", "-qc", "chore/issue-1-final"])
    File.write!(Path.join(ctx.workspace, "README.md"), "final\n")
    System.cmd("git", ["-C", ctx.workspace, "commit", "-qam", "chore: finalize"])

    plan = %{
      ctx.plan
      | "workflow" => "chore",
        "candidate" => %{
          "repository" => %{"origin" => "git@example.com:repo.git", "base_sha" => String.trim(base)},
          "affected_paths" => ["README.md"],
          "ordered_steps" => [
            %{
              "id" => "deliver",
              "depends_on" => [],
              "affected_paths" => ["README.md"],
              "proof_ids" => ["final"]
            }
          ],
          "proofs" => [proof("final", "deliver", "final", "success", "test -f README.md")]
        }
    }

    key = ExecutionLedger.key("git@example.com:repo.git", "issue-1", plan["plan_digest"] <> "-final")
    assert {:ok, _final} = ExecutionControl.run_plan_proof(plan, key, ctx.workspace, "deliver", "final")
    assert {:ok, _phase} = ExecutionControl.complete_execution_phase(plan, key, ctx.workspace, "deliver")
    assert {:ok, _delivery} = ExecutionControl.delivery_state(plan, key, ctx.workspace)

    File.write!(Path.join(ctx.workspace, "README.md"), "dirty\n")
    assert {:error, :delivery_requires_clean_tree} = ExecutionControl.delivery_state(plan, key, ctx.workspace)

    System.cmd("git", ["-C", ctx.workspace, "commit", "-qam", "chore: revise"])
    assert {:error, :final_proof_stale} = ExecutionControl.delivery_state(plan, key, ctx.workspace)
  end

  test "records timeout failures and exhausts their bounded attempts", ctx do
    slow = put_in(ctx.plan, ["candidate", "proofs"], [proof("red", "reproduce", "red", "failure", "sleep 1")])
    slow = put_in(slow, ["candidate", "proofs", Access.at(0), "timeout_ms"], 10)

    for attempt <- 1..3 do
      assert {:ok, receipt} = ExecutionControl.run_plan_proof(slow, ctx.key, ctx.workspace, "reproduce", "red")
      refute receipt["passed"]
      assert receipt["runner_error"] == "timeout"
      assert receipt["attempt"] == attempt
    end

    assert {:error, :proof_attempts_exhausted} =
             ExecutionControl.run_plan_proof(slow, ctx.key, ctx.workspace, "reproduce", "red")
  end

  test "records repository mutation by a final proof as failed evidence", ctx do
    plan = %{
      ctx.plan
      | "workflow" => "chore",
        "candidate" => %{
          ctx.plan["candidate"]
          | "proofs" => [
              proof(
                "final",
                "reproduce",
                "final",
                "success",
                "printf mutation >> README.md"
              )
            ]
        }
    }

    assert {:ok, receipt} =
             ExecutionControl.run_plan_proof(
               plan,
               ctx.key,
               ctx.workspace,
               "reproduce",
               "final"
             )

    refute receipt["passed"]
    assert receipt["freshness_error"] == "final_proof_requires_clean_stable_tree"
  end

  test "executes the same proof contract through the SSH worker boundary", ctx do
    fake_bin = Path.join(Path.dirname(ctx.workspace), "fake-bin")
    fake_ssh = Path.join(fake_bin, "ssh")
    previous_path = System.get_env("PATH")
    File.mkdir_p!(fake_bin)

    File.write!(fake_ssh, """
    #!/bin/sh
    for arg in "$@"; do remote_command="$arg"; done
    eval "$remote_command"
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))

    on_exit(fn ->
      if previous_path, do: System.put_env("PATH", previous_path), else: System.delete_env("PATH")
    end)

    assert {:ok, receipt} =
             ExecutionControl.run_plan_proof(
               ctx.plan,
               ctx.key,
               ctx.workspace,
               "reproduce",
               "red",
               worker_host: "worker-a"
             )

    assert receipt["passed"]
  end

  defp proof(id, phase_id, role, expected_exit, command) do
    %{"id" => id, "phase_id" => phase_id, "role" => role, "command" => command, "working_directory" => ".", "expected_exit" => expected_exit, "timeout_ms" => 1_000, "criterion_ids" => ["criterion-1"]}
  end
end
