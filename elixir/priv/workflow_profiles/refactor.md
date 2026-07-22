## Refactor profile

### Required phases

1. **Caller and coverage inventory:** enumerate callers, affected files, public contracts, and existing behavioral coverage. If coverage cannot prove preservation, add an approved prerequisite characterization proof or stop.
2. **Green baseline:** run the scoped baseline before editing and bind the successful event to the current head.
3. **Atomic transformations:** make one behavior-preserving structural change at a time. Keep the diff reviewable and rerun the scoped proof after each meaningful transformation.
4. **Full branch review:** compare the complete diff with the approved structural objective and reject accidental feature work, bug fixes, API changes, or test weakening.
5. **Final proof:** rerun the approved baseline and broader gate required by the selected profile against the final head.

### Workflow invariants

- Runtime behavior, public contracts, persisted data, error semantics, and externally observed ordering remain unchanged.
- Tests assert observable behavior, not the old internal structure.
- Every transformation begins and ends GREEN; unrelated cleanup stays out of the branch.

### Stop conditions

- Stop immediately when the baseline is red, a transformation changes behavior, required coverage is absent, or completing the objective requires a product or API decision.
