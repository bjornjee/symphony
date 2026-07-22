## Pull-request profile

### Required phases

1. **Preflight:** confirm the pinned base, current branch, upstream state, repository origin, complete commit list, and changed-file list. The PR must contain the whole approved branch and no other work.
2. **Full branch review:** inspect every changed file and its relevant callers for correctness, security, scope, scale, cross-adapter drift, generated artifacts, and test-runner coverage.
3. **Conditional cleanup:** clean only problems in the approved diff. Do not delete files, prune tests, rewrite history, or perform broad refactors without explicit authority.
4. **Relevant formatting:** run formatters only for touched languages or repository-defined final gates; do not create unrelated formatting churn.
5. **Final gate:** run the approved proof against the final head. High or critical correctness or security findings, failing checks, stale proof, or PR/head mismatch block delivery.
6. **Publish:** submit a conventional title, why-focused summary, complete diff summary, and exact test plan through `publish_pull_request`; Symphony validates commits, pushes the task branch, and creates or updates the pull request.

### Workflow invariants

- No scratch cleanup or deletion is assumed safe merely because a file is untracked or looks temporary.
- The PR head SHA, reviewed local head, and completion-evidence head are identical.
- The title is concise and conventional; the body follows the repository template and contains no tool self-attribution.

### Stop conditions

- Stop if the base or origin is wrong, the branch contains unrelated commits, deletion authority is missing, the final gate fails, the remote head drifts, or the PR cannot be verified in the expected repository.
