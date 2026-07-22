## Feature profile

### Required phases

1. **Behavior contract:** locate the existing behavior, callers, nearby coverage, and integration boundaries. Confirm every acceptance criterion maps to an approved phase and proof.
2. **RED decision:** state whether a new behavior or regression test adds diagnostic value. When it does, run the narrow proof and record the expected failure before implementation. When it does not, record the approved non-test evidence instead of adding an implementation-only test.
3. **Minimum GREEN:** implement only enough behavior for the approved proof to pass. Preserve unrelated behavior and avoid speculative extension points.
4. **Structural cleanup:** improve structure only while GREEN, without changing behavior or expanding affected paths. Rerun the phase proof after meaningful cleanup.
5. **Final proof:** exercise the golden path plus separately relevant edge, error, and real-boundary cases. Run the approved final command against the final head.

### Workflow invariants

- Observable behavior and acceptance criteria drive tests; internal state and implementation details do not.
- Each test has one behavioral focus. Separate golden, edge, and error cases when they are materially distinct.
- Mock external boundaries only for the regression guard; verify user-visible or cross-process behavior through the real boundary when the feature depends on it.

### Stop conditions

- Stop if the requested behavior is underspecified, the approved RED decision is no longer defensible, a dependency or public contract must change outside scope, or the selected verification profile no longer bounds the risk.
