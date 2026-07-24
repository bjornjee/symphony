# ADR 007: Supported browser capability fallback

## Context
Codex Browser backends are bound to their originating Desktop turn, while Symphony launches a separate app-server session. The supported app-server protocol cannot attach or delegate that backend.

## Decision
At app-server startup, Symphony distinguishes global configuration from runtime usability for Browser, Computer Use, and Playwright. A bound Codex Browser backend is preferred; otherwise a responsive inherited Playwright MCP is selected for deterministic automated rendering, inspection, screenshots, and behavior checks.

Browser execution is explicit in the sealed plan. Existing eight-field command proofs remain unchanged and never enter the browser path. A browser proof adds `type: "browser"` and a strict object containing only a literal loopback URL, fixture-readiness marker, and accessibility-snapshot assertions. Its command starts only the repository fixture through streaming sandboxed `command/exec`; the app-server worker resolves `HOME`, `PATH`, and `TMPDIR`, then all other environment variables are cleared. App-server network access remains enabled because the current sandbox exposes only a boolean and disables loopback binds when false; the browser audit requires an observed HTTP request on the sealed origin and rejects any recorded HTTP or WebSocket request outside it.

The engine then uses only fixed, schema-validated Playwright MCP tools through documented `mcpServer/tool/call` requests. It navigates to the sealed loopback URL, waits for the first assertion, captures a bounded accessibility snapshot and complete CRC-valid full-page PNG, verifies the final page plus every recorded HTTP and WebSocket request remain on the sealed origin, parses the engine-known console summary, and closes the browser. Repository content receives no browser endpoint, transport, arbitrary tool name, executable JavaScript, filename, process identifier, session identifier, raw observation, or browser response. The Playwright MCP uses its isolated automation profile, not an operator browsing profile. One monotonic deadline covers fixture readiness, browser checks, and cleanup; the engine always terminates and drains the fixture process. Missing capabilities, early fixture exits, missing network observations, origin drift, external requests, console errors, malformed or oversized MCP responses, timeouts, and cleanup failures fail closed with stable stage and code diagnostics.

Capability selection provenance and actual proof execution provenance are recorded separately in immutable proof receipts and audit events. Successful receipts retain only evidence hashes. Failures retain only actionable stage and code fields. Neither contains page text, screenshots, browser endpoints, process identifiers, session identifiers, or secrets.

## Consequences
Browser plugin enablement alone never implies a usable backend. Computer Use inheritance is verified independently. Existing command proofs retain their exact semantics. New browser proofs use a deterministic engine-owned render-and-inspect protocol and fail accurately when the inherited Playwright MCP is unavailable. A previously sealed Playwright command is not reinterpreted; it must be redispatched with a newly reviewed typed browser proof. Browser delegation remains an upstream Codex app-server dependency rather than a local transport workaround.

## Rollback
Before any typed browser plan is sealed, revert the additive proof variant and receipt fields. Existing command plans need no migration. Once a typed browser plan is sealed, keep this engine version available until that plan completes or explicitly replan it before rollback.
