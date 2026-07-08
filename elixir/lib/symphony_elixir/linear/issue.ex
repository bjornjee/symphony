defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    blocked_by: [],
    labels: [],
    label_ids_by_name: %{},
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          labels: [String.t()],
          label_ids_by_name: %{optional(String.t()) => String.t()},
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @spec has_label?(t(), String.t()) :: boolean()
  def has_label?(%__MODULE__{labels: labels}, label) when is_binary(label) do
    normalized_label = normalize_label(label)
    Enum.any?(labels, &(normalize_label(&1) == normalized_label))
  end

  @spec label_id_for_name(t(), String.t()) :: String.t() | nil
  def label_id_for_name(%__MODULE__{label_ids_by_name: label_ids_by_name}, label)
      when is_map(label_ids_by_name) and is_binary(label) do
    Map.get(label_ids_by_name, normalize_label(label)) || Map.get(label_ids_by_name, label)
  end

  def label_id_for_name(%__MODULE__{}, _label), do: nil

  @spec routable?(t(), [String.t()]) :: boolean()
  def routable?(%__MODULE__{assigned_to_worker: true, labels: labels}, required_labels)
      when is_list(labels) and is_list(required_labels) do
    issue_labels = MapSet.new(labels, &normalize_label/1)
    Enum.all?(required_labels, &MapSet.member?(issue_labels, normalize_label(&1)))
  end

  def routable?(%__MODULE__{}, _required_labels), do: false

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end
end
