# ADR 005: Conditional Preactivation Planning

Context: mandatory planning and medium review add avoidable latency to provably simple repository chores.

Decision: run a deterministic, engine-owned classification gate before planning and goal activation.

Decision: only eligible low-risk workflows with one path, criterion, and proof command may use direct execution; PR, CI, and build work remains planned.

Decision: ambiguity, risky-boundary signals, decomposition, and `Planning: full` always select the reviewed planning path.

Consequences: simple tasks retain digest-bound authority, branch, proof, PR, and handoff validation without native plan phases.

Rollback: remove the simple classification branch; existing planned artifacts remain valid and all new tasks return to reviewed planning.
