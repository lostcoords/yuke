# Reduction review close-out

## Scope and status

This review closes the broad checklist after commit `e91945d`.
It checks app and host ownership, session run ownership, shared test support,
and optional values in the catalog, session feed, and transcript renderer.
It uses the prior batch reports for the six original priorities.
Those six priorities are complete. This review does not certify every file in the repository.
Unrelated process and plugin edits in the current worktree are outside this review.
No production source or test changes in this pass.

## Concrete cleanup candidates

1. Catalog result guards: `src/js/app/catalog.js` checks `r` and falls back to empty provider/model arrays.
   `client.catalogList` promises `Wire.CatalogListResult`; `lib/proto/catalog.zig` requires both arrays for a full result.
   Remove the three redundant guards. Retain the `full` discriminator and the nullable initial catalog revision.
2. Session feed guards and fixtures: `src/js/app/sessions.js` accepts a typed page but checks absent items, sessions, titles, and activity state.
   The protocol requires those values. Timestamp fallbacks also duplicate the required numeric field.
   Align the consumed fixture fields before removal; `feed-refresh.test.js` currently supplies `activity: null` and partial sessions.
   Retain the refresh success and refusal tests. They verify replacement and preservation of feed state.
   Keep the empty-title fallback, no-model condition, and absent-session result; these are valid states.
3. Private view renderer guards: `src/js/app/transcript.js` falls back for diff files, hunks, lines, and view text.
   `lib/proto/view.zig` requires those fields. Narrow the view union and remove these fallbacks together.
   Preserve the optional tool view itself and failure handling at plugin callbacks.

These are concrete reduction candidates, not confirmed runtime defects or measured speed improvements.
Plugin advice remains supported. A plugin must supply the declared result shape.
No candidate requires removal of a public JS export or a wire schema change.
Exact line counts and allocation effects require the implementation diff and relevant benchmarks.

## Retained state and helpers

- `RunSlot.Prepared.slot` becomes null after bind transfers ownership; deinit must not free the transferred slot.
- `RunSlot.has_skills` starts unknown and becomes a cached database result.
- `Logs.dir` stays null until the first logged command; an unused host needs no log directory.
- The native engine runtime is null before attach and after detach.
- Terminal output can be absent in the headless frontend.
- `Refresh.flight` distinguishes idle from an active request shared by callers.
- A transcript part list is null after invalidation and reloads on demand.
- `defaultExpanded` accepts an absent tool state because `_isExpanded` also handles non-tool and missing parts.
- `app/fixture.zig` serves tests and release benchmarks. `Database.openTest` also serves the commit benchmark.
- `seedSession` and `execution.testContext` have shared test callers and no extra per-instance production fields.
- `execution.Probe` has native platform callbacks as well as test substitutes; it is not test-only state.

No further helper extraction or fixture relocation is justified by these checks.
No regression test in this scope was shown to be redundant.

## Performance status

The earlier boot allocation regression was resolved by the measured host allocator change.
The later agent-tree batch has a documented small boot latency cost; its report retains that tradeoff.
JSON buffer alternatives were measured in the prior review and had mixed allocation costs.
The current buffer allocator stays unchanged.
Paint-only invalidation and selection cost remain optional measurement topics.
They do not establish a remaining performance defect.

## Validation

This is a source review and documentation update. No new performance claim is made.
The last cleanup commit records its tests and benchmarks in `cleanup-evidence.md`.
No new test run is needed for these documentation edits.
The current unrelated worktree edits are not covered by that earlier validation.
