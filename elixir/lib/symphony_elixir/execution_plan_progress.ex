defmodule SymphonyElixir.ExecutionPlanProgress do
  @moduledoc """
  Validates implementation progress against the phases in an approved execution plan.
  """

  @spec validate(map(), [map()] | nil) :: :ok | {:error, term()}
  def validate(%{"candidate" => %{"ordered_steps" => approved}}, native_plan)
      when is_list(approved) do
    with {:ok, approved_phases} <- normalize_approved(approved),
         {:ok, native_phases} <- normalize_native(native_plan),
         :ok <- validate_phase_identity(approved_phases, native_phases) do
      validate_completion(approved_phases, native_phases)
    end
  end

  def validate(_execution_plan, _native_plan), do: {:error, :approved_execution_phases_missing}

  defp normalize_approved(phases) when phases != [] do
    reduce_phases(phases, fn
      %{"id" => id, "step" => step} when is_binary(id) and is_binary(step) ->
        {:ok, %{id: id, step: step}}

      _phase ->
        {:error, :approved_execution_phases_invalid}
    end)
  end

  defp normalize_approved(_phases), do: {:error, :approved_execution_phases_missing}

  defp normalize_native(nil), do: {:error, :native_plan_progress_missing}

  defp normalize_native(phases) when is_list(phases) and phases != [] do
    reduce_phases(phases, fn
      %{"step" => step, "status" => status}
      when is_binary(step) and status in ~w(pending in_progress completed) ->
        {:ok, %{step: step, status: status}}

      %{step: step, status: status}
      when is_binary(step) and status in ~w(pending in_progress completed) ->
        {:ok, %{step: step, status: status}}

      _phase ->
        {:error, :invalid_native_plan_progress}
    end)
  end

  defp normalize_native(_phases), do: {:error, :invalid_native_plan_progress}

  defp reduce_phases(phases, normalizer) do
    Enum.reduce_while(phases, {:ok, []}, fn phase, {:ok, acc} ->
      case normalizer.(phase) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_phase_identity(approved, native) do
    if Enum.map(approved, & &1.step) == Enum.map(native, & &1.step),
      do: :ok,
      else: {:error, :native_plan_phase_drift}
  end

  defp validate_completion(approved, native) do
    incomplete_ids =
      approved
      |> Enum.zip(native)
      |> Enum.reject(fn {_approved, observed} -> observed.status == "completed" end)
      |> Enum.map(fn {phase, _observed} -> phase.id end)

    if incomplete_ids == [],
      do: :ok,
      else: {:error, {:native_plan_incomplete, incomplete_ids}}
  end
end
