defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]
  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    prompt =
      template
      |> Solid.render!(
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "issue" => issue |> Map.from_struct() |> to_solid_map()
        },
        @render_opts
      )
      |> IO.iodata_to_binary()
      |> maybe_append_workflow_profile(Keyword.get(opts, :workflow_profile))

    maybe_append_completion_evidence_contract(
      prompt,
      Keyword.get(opts, :task_contract),
      Keyword.get(opts, :execution_plan)
    )
  end

  @spec build_execution_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_execution_prompt(issue, opts) do
    execution_plan = Keyword.fetch!(opts, :execution_plan)

    prompt =
      """
      The preactivation planning gate is complete and the Codex goal is active.

      Execute only the approved execution plan below. It is the implementation authority for Linear #{issue.identifier}; do not reinterpret the raw Linear description as permission to expand scope.
      Preserve the native plan created during preactivation. Execute its typed phases in order, keep exactly one phase in progress, and mark a phase completed only after its proof and evidence requirements pass.
      Do not add, remove, rename, reorder, or skip approved phases. Symphony rejects handoff unless the final native plan exactly matches the approved phases and every phase is completed.
      Create or resume the single task branch from the pinned base SHA before the first source edit. Reuse this issue workspace and never create a nested worktree.
      Follow the approved verification profile and exact proof commands. Produce the required PR and Symphony-validated completion evidence.

      Approved plan digest: #{execution_plan["plan_digest"]}
      Approved execution plan:
      ```json
      #{Jason.encode!(execution_plan["candidate"], pretty: true)}
      ```
      """
      |> String.trim()
      |> maybe_append_workflow_profile(Keyword.get(opts, :workflow_profile))

    maybe_append_completion_evidence_contract(
      prompt,
      Keyword.get(opts, :task_contract),
      execution_plan
    )
  end

  defp maybe_append_completion_evidence_contract(
         prompt,
         %SymphonyElixir.Linear.TaskContract{} = contract,
         execution_plan
       ) do
    criteria =
      Enum.map(contract.acceptance_criteria, fn criterion ->
        %{
          "criterion_id" => criterion.id,
          "proof" => %{
            "kind" => "run_audit_command",
            "event_id" => "<engine-observed proof event_id>"
          }
        }
      end)

    envelope = %{
      "schema_version" => 2,
      "issue_id" => "<current issue id>",
      "issue_identifier" => "<current issue identifier>",
      "plan_digest" => contract.digest,
      "execution_plan_digest" => plan_value(execution_plan, "plan_digest"),
      "workflow" => plan_value(execution_plan, "workflow"),
      "profile_digest" => plan_value(execution_plan, "profile_digest"),
      "criteria" => criteria,
      "workflow_proof" => workflow_proof_shape(execution_plan),
      "pull_request_url" => "https://github.com/<owner>/<repository>/pull/<number>",
      "pr_head_sha" => "<exact PR head SHA>",
      "repository_head_sha" => "<same reviewed final local HEAD SHA>"
    }

    criterion_index =
      Enum.map_join(contract.acceptance_criteria, "\n", fn criterion ->
        "- `#{criterion.id}`: #{criterion.text}"
      end)

    """
    #{prompt}

    Machine-validated handoff evidence (required before the configured handoff state):

    - Write `.symphony/completion-evidence.json` only after the proof commands and repository PR exist.
    - Before writing completion evidence, update the native plan so every approved execution phase is `completed`; Symphony validates exact phase identity and completion independently.
    - Copy `issue_id`, `issue_identifier`, and `plan_digest` exactly from `.symphony/execution-manifest.json`; copy `execution_plan_digest`, `workflow`, and `profile_digest` from `.symphony/execution-plan.json`.
    - Write a temporary file in `.symphony/`, then atomically rename it to that path. Replacing the same plan-digest envelope is idempotent.
    - For every criterion below, reference an `event_id` from an engine-written command-completion audit event whose `exit_code` is `0` and whose proof command covers that criterion.
    - Populate `workflow_proof` with the workflow-specific RED/GREEN, baseline/final, validator, or Surgical review evidence required by the approved plan.
    - Set both head SHA fields to the final reviewed commit. Proof against an older local head or a PR whose head differs is rejected.
    - Do not use prose, checkbox state, edited audit JSON, or your own claimed exit code as proof; Symphony validates references against its in-memory event ledger.
    - `pull_request_url` must be an existing HTTPS GitHub pull request URL for this workspace's `origin` repository. Symphony resolves it with `gh pr view`; an invented, inaccessible, issue, compare, branch, or cross-repository URL is rejected.
    - Do not create the completed-work `## Agent Handoff` comment or move the issue to the configured handoff state. Symphony validates this artifact, publishes and reads back the deterministic handoff, then performs that state transition.

    Pinned acceptance criteria:
    #{criterion_index}

    Completion evidence v2 shape:

    ```json
    #{Jason.encode!(envelope, pretty: true)}
    ```
    """
    |> String.trim()
  end

  defp maybe_append_completion_evidence_contract(prompt, _contract, _execution_plan), do: prompt

  defp plan_value(plan, key) when is_map(plan), do: Map.get(plan, key, "<approved #{key}>")
  defp plan_value(_plan, key), do: "<approved #{key}>"

  defp workflow_proof_shape(%{"workflow" => "fix"}),
    do: %{"red_event_id" => "<failing event>", "green_event_id" => "<later passing event>"}

  defp workflow_proof_shape(%{"workflow" => "refactor"}),
    do: %{"baseline_event_id" => "<green baseline>", "final_proof_event_id" => "<final green proof>"}

  defp workflow_proof_shape(%{"workflow" => "chore"}),
    do: %{"validator_event_id" => "<validator event, or use surgical_review>"}

  defp workflow_proof_shape(_execution_plan),
    do: %{"final_proof_event_id" => "<final green proof>", "red_event_id" => "<when required by plan>"}

  defp maybe_append_workflow_profile(prompt, %SymphonyElixir.WorkflowProfile{} = profile) do
    """
    #{prompt}

    Trusted Symphony workflow profile:

    - name: `#{profile.name}`
    - version: `#{profile.version}`
    - digest: `#{profile.digest}`

    #{profile.instructions}
    """
    |> String.trim()
  end

  defp maybe_append_workflow_profile(prompt, _profile), do: prompt

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
