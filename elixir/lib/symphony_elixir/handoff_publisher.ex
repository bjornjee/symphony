defmodule SymphonyElixir.HandoffPublisher do
  @moduledoc """
  Publishes one deterministic, read-verified tracker handoff before state transition.
  """

  import Bitwise
  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.{Issue, TaskContract}
  alias SymphonyElixir.Tracker

  @marker_prefix "symphony-agent-handoff:v1"

  @type evidence :: %{
          required(:artifact_digest) => String.t(),
          required(:criteria) => [%{required(:criterion_id) => String.t(), required(:proof_event_id) => String.t()}],
          required(:pull_request_url) => String.t()
        }

  @spec publish(Issue.t(), TaskContract.t(), evidence(), keyword()) ::
          {:ok, %{comment_id: String.t(), issue_state: String.t()}} | {:error, term()}
  def publish(%Issue{} = issue, %TaskContract{} = contract, evidence, opts \\ [])
      when is_map(evidence) and is_list(opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)

    handoff_state =
      Keyword.get_lazy(opts, :handoff_state, fn -> Config.settings!().tracker.handoff_state end)

    comment_id = comment_id(issue, contract, evidence)
    body = render(issue, contract, evidence)

    with :ok <- ensure_comment(tracker, issue.id, comment_id, body),
         :ok <- log_comment_verified(issue, comment_id, evidence.artifact_digest),
         :ok <- transition_issue(tracker, issue.id, handoff_state) do
      Logger.info("Linear handoff state transitioned issue_id=#{issue.id} issue_identifier=#{issue.identifier} comment_id=#{comment_id} issue_state=#{handoff_state}")

      {:ok, %{comment_id: comment_id, issue_state: handoff_state}}
    end
  end

  @spec comment_id(Issue.t(), TaskContract.t(), evidence()) :: String.t()
  def comment_id(%Issue{id: issue_id}, %TaskContract{digest: plan_digest}, %{artifact_digest: artifact_digest}) do
    digest = handoff_digest(issue_id, plan_digest, artifact_digest)
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> = digest
    c = (c &&& 0x0FFF) ||| 0x4000
    d = (d &&& 0x3FFF) ||| 0x8000

    [
      hex(a, 8),
      "-",
      hex(b, 4),
      "-",
      hex(c, 4),
      "-",
      hex(d, 4),
      "-",
      hex(e, 12)
    ]
    |> IO.iodata_to_binary()
  end

  @spec render(Issue.t(), TaskContract.t(), evidence()) :: String.t()
  def render(%Issue{} = issue, %TaskContract{} = contract, evidence) when is_map(evidence) do
    validated_criterion_ids = MapSet.new(evidence.criteria, & &1.criterion_id)

    criterion_lines =
      Enum.map_join(contract.acceptance_criteria, "\n", fn criterion ->
        true = MapSet.member?(validated_criterion_ids, criterion.id)
        "- ✅ #{inline_text(criterion.text)} — passed with engine-observed command evidence"
      end)

    marker_key = marker_key(issue, contract, evidence)

    """
    ## Agent Handoff

    PR: #{evidence.pull_request_url}

    ### Acceptance criteria

    #{criterion_lines}

    Verification: #{length(contract.acceptance_criteria)} acceptance criteria passed with engine-observed command evidence.

    Human action: Review and approve the pull request.

    <!-- #{@marker_prefix} key=#{marker_key} -->
    """
    |> String.trim()
  end

  defp ensure_comment(tracker, issue_id, comment_id, body) do
    case tracker.fetch_comment(issue_id, comment_id) do
      {:ok, nil} -> create_and_verify_comment(tracker, issue_id, comment_id, body)
      {:ok, %{id: ^comment_id, body: ^body}} -> :ok
      {:ok, %{id: ^comment_id}} -> {:error, {:handoff_comment_collision, comment_id}}
      {:error, reason} -> {:error, {:handoff_comment_read_failed, reason}}
      other -> {:error, {:handoff_comment_read_failed, other}}
    end
  end

  defp create_and_verify_comment(tracker, issue_id, comment_id, body) do
    create_result = tracker.create_comment(issue_id, comment_id, body)

    case tracker.fetch_comment(issue_id, comment_id) do
      {:ok, %{id: ^comment_id, body: ^body}} -> :ok
      {:ok, %{id: ^comment_id}} -> {:error, {:handoff_comment_collision, comment_id}}
      {:ok, nil} -> {:error, {:handoff_comment_unverified, comment_id, create_result}}
      {:error, reason} -> {:error, {:handoff_comment_read_failed, reason, create_result}}
      other -> {:error, {:handoff_comment_read_failed, other, create_result}}
    end
  end

  defp transition_issue(tracker, issue_id, handoff_state) do
    case tracker.update_issue_state(issue_id, handoff_state) do
      :ok -> :ok
      {:error, reason} -> {:error, {:handoff_state_transition_failed, handoff_state, reason}}
      other -> {:error, {:handoff_state_transition_failed, handoff_state, other}}
    end
  end

  defp log_comment_verified(issue, comment_id, artifact_digest) do
    Logger.info("Linear handoff comment verified issue_id=#{issue.id} issue_identifier=#{issue.identifier} comment_id=#{comment_id} artifact_digest=#{artifact_digest}")
  end

  defp marker_key(%Issue{id: issue_id}, %TaskContract{digest: plan_digest}, %{artifact_digest: artifact_digest}) do
    issue_id
    |> handoff_digest(plan_digest, artifact_digest)
    |> Base.encode16(case: :lower)
  end

  defp handoff_digest(issue_id, plan_digest, artifact_digest) do
    :crypto.hash(:sha256, [@marker_prefix, 0, issue_id, 0, plan_digest, 0, artifact_digest])
  end

  defp inline_text(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> then(&Regex.replace(~r/([\\`*_{}\[\]()#|])/u, &1, fn match -> "\\" <> match end))
  end

  defp hex(value, width) do
    value
    |> Integer.to_string(16)
    |> String.pad_leading(width, "0")
  end
end
