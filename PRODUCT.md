# Product

## Register

product

## Users

The primary user is the engineer operating Symphony. They need to monitor autonomous
agent work without supervising every step, understand what each agent is doing now,
and decide quickly when a run needs attention.

The core workflow is:

1. Scan all active, retrying, blocked, stale, or unavailable agents.
2. Select one agent to inspect its actions and progress.
3. Follow recent activity with the immediacy and clarity of Codex streaming output.
4. Identify the next operator action when a run needs approval, input, or recovery.

## Product Purpose

Symphony turns project work into isolated autonomous implementation runs. Its
dashboard makes those runs legible and actionable: what is running, what changed,
how far it has progressed, why it is waiting, and what the operator should do next.

Success means the operator can understand the fleet at a glance, inspect one agent's
live narrative without leaving the dashboard, and trust that every status reflects
runtime reality.

## Brand Personality

Calm, precise, and operational, expressed through a contemporary product design
language. The interface should feel current in the way Codex does: clear hierarchy,
focused live activity, restrained motion, and progressive disclosure without visual
noise.

Physical scene: one engineer monitors several long-running agents on a work display,
moving between ambient awareness and focused diagnosis without losing context.

Reference anchor: the Codex task experience, specifically its streaming action and
progress presentation. It is an interaction and quality reference, not a
pixel-for-pixel visual specification.

## Anti-references

- Dense tables or raw JSON as the primary way to understand agent activity.
- A pixel-for-pixel Codex clone that obscures Symphony's own operational needs.
- Generic SaaS card walls, decorative glass effects, or neon command-center styling.
- Activity feeds that animate for spectacle, hide chronology, or imply progress that
  the runtime has not confirmed.
- Status treatments that rely only on color or bury the required operator action.

## Design Principles

1. **Show actions before aggregates.** Lead with what agents are doing and what changed;
   metrics support that story rather than replacing it.
2. **Scan first, inspect in place.** Keep the fleet overview concise, then reveal a
   selected agent's richer timeline without navigation or context loss.
3. **Make runtime truth visible.** Distinguish live, stale, retrying, blocked, and
   unavailable states without optimistic inference.
4. **Keep density purposeful.** Use progressive disclosure for identifiers, tokens,
   audit data, and workspace details while preserving quick access.
5. **Stay calm under pressure.** Prioritize precise language, stable layouts, and
   restrained motion so failures remain understandable and actionable.

## Accessibility & Inclusion

Target WCAG 2.2 AA. Support keyboard-only navigation, visible focus, semantic status
announcements, readable contrast, reduced-motion preferences, and status cues that
do not depend on color alone. Preserve selection and reading position during live
updates.
