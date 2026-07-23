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

    prompt
    |> maybe_append_completion_evidence_contract(
      Keyword.get(opts, :task_contract),
      Keyword.get(opts, :execution_plan)
    )
    |> maybe_append_capability_diagnostics(Keyword.get(opts, :capability_diagnostics))
  end

  @spec build_execution_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_execution_prompt(issue, opts) do
    execution_plan = Keyword.fetch!(opts, :execution_plan)

    prompt =
      execution_prompt(issue, execution_plan)
      |> maybe_append_workflow_profile(Keyword.get(opts, :workflow_profile))

    prompt
    |> maybe_append_completion_evidence_contract(
      Keyword.get(opts, :task_contract),
      execution_plan
    )
    |> maybe_append_capability_diagnostics(Keyword.get(opts, :capability_diagnostics))
  end

  defp execution_prompt(issue, %{"execution_mode" => "simple"} = execution_plan) do
    """
    Symphony's preactivation classification gate approved direct execution and the Codex goal is active.

    This is a simple task, so no native implementation plan or automated plan review is required. Do not create a plan merely to restate the task.
    Work only on the single approved path for Linear #{issue.identifier}; the pinned contract and direct execution authorization below are the implementation authority.
    Create or resume the single task branch from the pinned base SHA before the first source edit. Reuse this issue workspace and never create a nested worktree.
    Commit the final tree, call `run_plan_proof` for the exact approved final proof, and call `publish_pull_request`. Symphony alone runs proofs, pushes, creates the PR, and generates completion evidence.
    Do not run proof commands in your shell, push, invoke GitHub, or write `.symphony/completion-evidence.json` yourself.
    Stop and report the concrete reason if another path, proof command, workflow, or higher-risk boundary becomes necessary; do not silently promote or expand the task during implementation.

    Direct execution digest: #{execution_plan["plan_digest"]}
    Direct execution authorization:
    ```json
    #{Jason.encode!(Map.drop(execution_plan, ["plan_digest"]), pretty: true)}
    ```
    """
    |> String.trim()
  end

  defp execution_prompt(issue, execution_plan) do
    """
    The preactivation planning gate is complete and the Codex goal is active.

    Execute only the approved execution plan below. It is the implementation authority for Linear #{issue.identifier}; do not reinterpret the raw Linear description as permission to expand scope.
    Preserve the native plan created during preactivation. Execute its typed phases in order, keep exactly one phase in progress, and mark a phase completed only after its proof and evidence requirements pass.
    Do not add, remove, rename, reorder, or skip approved phases. Symphony rejects handoff unless the final native plan exactly matches the approved phases and every phase is completed.
    A failed proof receipt is evidence, not a permanent blocker. If that proof is still the earliest incomplete gate and attempts remain, call `run_plan_proof` again to observe the current engine behavior; a restarted Symphony runtime may contain the correction for the prior failure.
    When a failed receipt reports zero attempts remaining, stop the turn. Symphony publishes the deterministic Human Review blocker; do not retry or substitute another command.
    Create or resume the single task branch from the pinned base SHA before the first source edit. Reuse this issue workspace and never create a nested worktree.
    Call `run_plan_proof` for each approved proof ID and `complete_execution_phase` after its dependencies and proofs pass. For fixes, call `submit_fix_diagnosis` after RED and before GREEN.
    After all phases, commit the final tree and rerun the final proof against the clean commit. Then call `request_implementation_review`; address a revise verdict and rerun stale final proof before requesting review again. Once approved, call `publish_pull_request`.
    Do not run approved proofs in your shell, push, invoke GitHub, use network access, or write completion evidence. Symphony owns those actions.

    Approved plan digest: #{execution_plan["plan_digest"]}
    Approved execution plan:
    ```json
    #{Jason.encode!(execution_plan["candidate"], pretty: true)}
    ```
    """
    |> String.trim()
  end

  defp maybe_append_completion_evidence_contract(
         prompt,
         %SymphonyElixir.Linear.TaskContract{} = contract,
         execution_plan
       ) do
    criterion_index =
      Enum.map_join(contract.acceptance_criteria, "\n", fn criterion ->
        "- `#{criterion.id}`: #{criterion.text}"
      end)

    """
    #{prompt}

    Engine-owned delivery contract:

    - Approved commands may only be executed with `run_plan_proof`; agent shell command events never satisfy proof contracts.
    #{plan_progress_instruction(execution_plan)}
    - Commit before the final proof. Any edit or commit invalidates final proof and implementation-review approval.
    - Planned or Full work requires `request_implementation_review`. Two revisions are allowed; a third rejection moves the issue to Human Review.
    - `publish_pull_request` is the only push/PR path. Its body must contain `## Why`, `## Summary`, and an exact `## Test plan` listing every approved command.
    - Symphony generates completion evidence from trusted external receipts and owns the Linear handoff. Never create or edit completion evidence, the handoff comment, or issue state.

    Pinned acceptance criteria:
    #{criterion_index}

    Approved execution plan: `#{plan_value(execution_plan, "plan_digest")}`
    """
    |> String.trim()
  end

  defp maybe_append_completion_evidence_contract(prompt, _contract, _execution_plan), do: prompt

  defp plan_progress_instruction(%{"execution_mode" => "simple"}),
    do: "- This direct execution has no approved native-plan phases; do not manufacture a plan-progress update for handoff."

  defp plan_progress_instruction(_execution_plan),
    do: "- Before writing completion evidence, update the native plan so every approved execution phase is `completed`; Symphony validates exact phase identity and completion independently."

  defp plan_value(plan, key) when is_map(plan), do: Map.get(plan, key, "<approved #{key}>")
  defp plan_value(_plan, key), do: "<approved #{key}>"

  defp maybe_append_workflow_profile(prompt, %SymphonyElixir.WorkflowProfile{} = profile) do
    """
    #{prompt}

    Trusted Symphony workflow profile:

    - name: `#{profile.name}`
    - digest: `#{profile.digest}`

    #{profile.instructions}
    """
    |> String.trim()
  end

  defp maybe_append_workflow_profile(prompt, _profile), do: prompt

  defp maybe_append_capability_diagnostics(
         prompt,
         %{browser_path: path, browser: browser, computer_use: computer_use, playwright: playwright}
       ) do
    """
    #{prompt}

    Runtime capability diagnostics:

    - selected browser path: `#{path.selected}`
    - provenance: `#{path.provenance || "none"}`
    - selection code: `#{path.code}`
    - Browser: configured=#{browser.configured}, usable=#{browser.usable}, code=`#{browser.code}`
    - Playwright: configured=#{playwright.configured}, usable=#{playwright.usable}, code=`#{playwright.code}`
    - Computer Use: configured=#{computer_use.configured}, usable=#{computer_use.usable}, code=`#{computer_use.code}`
    - #{path.message}
    - Action: #{path.action}

    Browser plugin enablement is configuration only. Use the selected path for browser and UI verification, and do not claim visual verification unless that runtime backend renders and inspects the target UI.
    """
    |> String.trim()
  end

  defp maybe_append_capability_diagnostics(prompt, _diagnostics), do: prompt

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
