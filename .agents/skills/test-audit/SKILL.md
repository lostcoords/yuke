---
name: test-audit
description: Audit, consolidate, or remove existing Yuke tests and test-only production seams. Use for focused test-debt reviews, test-pruning plans, and subsystem campaigns. Do not use for a routine focused regression test unless the user asks for an audit.
---

# Test audit

AGENTS.md rules apply. This skill adds the evidence required to change existing
coverage. Optimize for confidence, not deleted lines.

## Scope

Use one mode.

- **Focused audit:** Review a small set of suspicious or changed tests.
- **Campaign:** Review every test and test-support file in one subsystem. Load
  [CAMPAIGN.md](CAMPAIGN.md) only after the user approves this mode.

Keep a test when it protects observable behavior, an independent boundary, or
a credible regression. Do not remove a test because it is old, slow, detailed,
or difficult to refactor.

## Audit method

Before judging a test, read its complete body and its production owner. Read
the owner entry point, callers, callees, sibling implementations, overlapping
tests, and relevant history.

For a JS test, find its owning Zig test. `src/js/tests/README.md` defines the
boundary. Keep native state, allocation, paint, and resource ownership checks
in Zig. Keep JS state and behavior checks in JS. Do not add test-only exports
to cross this boundary.

A test is suspect when it only:

- repeats a stronger owner-boundary test;
- asserts a private call shape instead of observable behavior;
- greps source, imports, or incidental strings;
- calculates the expected value with the owner under test;
- uses a mock or fixture that supplies the asserted behavior;
- preserves a test-only export, global, wrapper, or dead production path; or
- passes a negative case through a guard other than the claimed guard.

These patterns are candidates, not deletion proof. Retain independent
contracts. Likely retained Yuke contracts include RPC and protocol bytes, SQL
migrations and generated queries, generated schemas and declarations, terminal
input and rendering, QuickJS host lifecycle, cancellation, and ownership or
allocation invariants.

## Candidate record

Record each proposed deletion or consolidation before editing:

1. Test name and path.
2. The failure that it can detect now.
3. The covered production or support seam and its non-test callers.
4. The stronger remaining owner-boundary proof, or why no proof is needed.
5. Relevant history and the reason for the test or seam.
6. Production or test-support code that the change removes.
7. Risk and the focused validation command.

A missing record means retain the test. A baseline failure can be a product
defect. Reproduce and repair its production owner. Do not delete it as stale.

## Edit and proof

Make one coherent owner-boundary batch. Remove obsolete test-only seams rather
than preserve aliases. Move a retained regression to its canonical owner when
that improves the boundary. Do not add a replacement that repeats the same
implementation.

Run the smallest relevant owner test first. For QuickJS host tests, use:

```sh
zig build test-js --seed 0 -Dtest-filter='<owner test name>'
```

Follow the required checks in AGENTS.md while you work and before a commit. Run
`git diff --check`. If the change affects the JS host, engine, or renderer,
perform the benchmark work that AGENTS.md requires.

Report retained contracts, removed low-value categories, removed production or
test-support seams, proof run, and named follow-up candidates.
