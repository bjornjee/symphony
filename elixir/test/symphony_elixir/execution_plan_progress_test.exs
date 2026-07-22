defmodule SymphonyElixir.ExecutionPlanProgressTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExecutionPlanProgress

  test "accepts only the exact approved phases when every phase is completed" do
    plan = execution_plan()

    assert :ok =
             ExecutionPlanProgress.validate(plan, [
               %{"step" => "Reproduce the defect", "status" => "completed"},
               %{"step" => "Implement and prove the fix", "status" => "completed"}
             ])
  end

  test "rejects missing, incomplete, reordered, and expanded native plans" do
    plan = execution_plan()

    assert {:error, :native_plan_progress_missing} = ExecutionPlanProgress.validate(plan, nil)

    assert {:error, {:native_plan_incomplete, ["fix"]}} =
             ExecutionPlanProgress.validate(plan, [
               %{"step" => "Reproduce the defect", "status" => "completed"},
               %{"step" => "Implement and prove the fix", "status" => "in_progress"}
             ])

    assert {:error, :native_plan_phase_drift} =
             ExecutionPlanProgress.validate(plan, [
               %{"step" => "Implement and prove the fix", "status" => "completed"},
               %{"step" => "Reproduce the defect", "status" => "completed"}
             ])

    assert {:error, :native_plan_phase_drift} =
             ExecutionPlanProgress.validate(plan, [
               %{"step" => "Reproduce the defect", "status" => "completed"},
               %{"step" => "Implement and prove the fix", "status" => "completed"},
               %{"step" => "Unapproved cleanup", "status" => "completed"}
             ])
  end

  test "rejects malformed native plan updates" do
    assert {:error, :invalid_native_plan_progress} =
             ExecutionPlanProgress.validate(execution_plan(), [%{"step" => "Missing status"}])
  end

  defp execution_plan do
    %{
      "candidate" => %{
        "ordered_steps" => [
          %{"id" => "reproduce", "step" => "Reproduce the defect"},
          %{"id" => "fix", "step" => "Implement and prove the fix"}
        ]
      }
    }
  end
end
