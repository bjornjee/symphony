# ADR 004: Plan Before Goal with Native Workflows

Context: Symphony cannot assume the agent-dashboard plugin exists, and goal-first execution cannot bind implementation authority to an approved plan.

Decision: package Symphony-owned workflow profiles and run read-only native planning plus an isolated medium-effort review before goal activation.

Decision: persist at most three immutable candidates and reviews, then seal one create-only execution plan whose digest is bound into the goal and completion evidence.

Decision: infer restart state from immutable artifacts; do not add a mutable workflow-state file or a plugin fallback.

Consequences: preactivation time and tokens are outside native goal accounting, with at most six turns.

Consequences: contract, profile, thread, repository, plan, review, proof, and PR-head drift fail closed.

Rollback: retain phase-one Symphony profiles and revert the preactivation runner and v2 evidence validation to the former goal-first runner.
