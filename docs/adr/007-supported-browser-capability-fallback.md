# ADR 007: Supported browser capability fallback

## Context
Codex Browser backends are bound to their originating Desktop turn, while Symphony launches a separate app-server session. The supported app-server protocol cannot attach or delegate that backend.

## Decision
At app-server startup, Symphony distinguishes global configuration from runtime usability for Browser, Computer Use, and Playwright. A bound Codex Browser backend is preferred; otherwise a responsive inherited Playwright MCP is selected for deterministic automated rendering, inspection, screenshots, and behavior checks. The selected path, provenance, diagnostic code, and action are exposed in prompts, audit events, runtime snapshots, APIs, and the dashboard.

## Consequences
Browser plugin enablement alone never implies a usable backend. Computer Use inheritance is verified independently. Visual workflows fail accurately when neither backend responds, and Browser delegation remains an upstream Codex app-server dependency rather than a local transport workaround.

## Rollback
Revert the additive diagnostic fields and startup probes; existing agent execution and observability schemas accept their absence.
