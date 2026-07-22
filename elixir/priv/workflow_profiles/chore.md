## Chore profile

### Required phases

1. **Routing gate:** confirm the task is limited to documentation, configuration, dependencies, generated metadata, CI, build files, or mechanical edits. If it changes application or agent behavior, route it to feature, fix, or refactor instead.
2. **Bounded change:** edit only the declared files and preserve generated-file ownership, cross-adapter parity, and repository conventions.
3. **Validation escalation:** use Surgical review for text-only work with no meaningful executable assertion. Escalate to Full verification for dependency, CI, build, formatter, test-runner, or shared infrastructure changes.
4. **Delivery:** review the exact diff, use the matching conventional commit type (`docs`, `ci`, `build`, or `chore`), and run the approved validator or final gate.

### Workflow invariants

- Do not add tests that merely restate configuration or generated output.
- Generated artifacts are changed through their owning generator when one exists.
- Dependency and infrastructure changes include lockfiles and all repository-defined validation they affect.

### Stop conditions

- Stop if application behavior changes, the correct generator is unavailable, equivalent adapters drift, or the change requires credentials, publishing authority, or destructive cleanup not granted by the plan.
