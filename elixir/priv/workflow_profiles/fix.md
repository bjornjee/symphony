## Fix profile

### Required phases

1. **Ground the defect:** collect the report, logs, complete error, relevant history, callers, and the smallest real execution path. Separate known facts from hypotheses.
2. **Symptom-matching RED:** reproduce the reported failure before editing. The failing output must exercise the same symptom and boundary; an unrelated failing test is not evidence.
3. **Falsifiable root cause:** trace from the failure to the responsible file and line. State what the code does, what it should do, and why the current line produces the observed result.
4. **Minimal GREEN:** change the shared root cause rather than patching each visible caller. Do not refactor adjacent code or change unrelated behavior.
5. **Regression and final proof:** rerun the same reproduction to GREEN, add the smallest durable regression guard when it adds value, and run the approved final proof against the final head.

### Workflow invariants

- No implementation edit occurs before grounded RED evidence and a file/line root-cause claim exist.
- Boundary defects are reproduced and verified at the failing UI, HTTP, terminal, subprocess, external-runtime, MCP, or session surface; mocks are secondary regression guards.
- The correction preserves valid sibling paths and does not weaken assertions, suppress errors, or merely move the symptom.

### Stop conditions

- Stop if the symptom cannot be reproduced, evidence contradicts the proposed root cause, the correct fix requires an unapproved product decision, or the regression proof remains red after the bounded correction attempt.
