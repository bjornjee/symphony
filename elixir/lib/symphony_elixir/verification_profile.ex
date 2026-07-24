defmodule SymphonyElixir.VerificationProfile do
  @moduledoc "Resolves the effective verification profile from the approved plan and observed diff."

  @profiles ~w(Surgical Targeted Full)

  @type resolution :: %{
          optional(:reason) => String.t(),
          selected: String.t(),
          effective: String.t(),
          escalated: boolean()
        }

  @spec resolve(map(), [String.t()]) ::
          {:ok, resolution()}
          | {:error, {:verification_profile_escalation_required, map()}}
  def resolve(plan, changed_paths) when is_map(plan) and is_list(changed_paths) do
    selected = selected(plan)
    approved = approved_paths(plan)
    outside = Enum.reject(changed_paths, &approved_path?(&1, approved))

    cond do
      selected not in @profiles ->
        {:ok,
         %{
           selected: selected || "Uncertain",
           effective: "Full",
           escalated: true,
           reason: "verification profile is uncertain"
         }}

      outside != [] ->
        {:error,
         {:verification_profile_escalation_required,
          %{
            selected: selected,
            effective: "Full",
            reason: "changed path outside approved scope",
            changed_paths: changed_paths
          }}}

      selected == "Surgical" and length(changed_paths) > 1 ->
        {:ok,
         %{
           selected: selected,
           effective: "Targeted",
           escalated: true,
           reason: "expanded approved diff"
         }}

      true ->
        {:ok, %{selected: selected, effective: selected, escalated: false}}
    end
  end

  defp selected(%{"verification_profile" => profile}), do: profile
  defp selected(%{"candidate" => %{"verification_profile" => profile}}), do: profile
  defp selected(_plan), do: nil

  defp approved_paths(%{"affected_paths" => paths}) when is_list(paths), do: paths
  defp approved_paths(%{"candidate" => %{"affected_paths" => paths}}) when is_list(paths), do: paths
  defp approved_paths(_plan), do: []

  defp approved_path?(changed_path, allowed) when is_binary(changed_path) do
    Enum.any?(allowed, fn path ->
      changed_path == path or
        String.starts_with?(changed_path, String.trim_trailing(path, "/") <> "/")
    end)
  end

  defp approved_path?(_changed_path, _allowed), do: false
end
