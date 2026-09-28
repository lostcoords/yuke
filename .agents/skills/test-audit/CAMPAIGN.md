# Test-pruning campaign

Campaign mode audits one subsystem's complete test surface. It is a hardening
project, not routine release work. Use it only after the user approves a named
scope and the baseline is stable.

The rules and candidate record in [SKILL.md](SKILL.md) apply to every test.
Optimize for preserved contracts, not deletion count.

## 1. Baseline

Pin the starting commit. Record:

- production, test, and test-support line counts;
- every in-scope test and its pass or fail result;
- focused test commands and full-suite result; and
- known baseline failures in a separate list.

A baseline failure can be a product defect. Do not classify it as stale coverage.

## 2. Scope and lanes

Name one subsystem and include all of its tests, test support, and live or QA
proof. Include shared boundaries that the subsystem owns.

Divide the work into lanes by production owner boundary, not by directory name.
Each test file and QA scenario belongs to exactly one lane.

For Yuke, a JS lane includes its owning Zig test. Do not separate the JS file
from the host, native state, or lifecycle proof that makes its contract valid.

## 3. Read-only ledger

Read every declaration in a lane and its owner. Record one decision for each
test, or for each table row when rows cover different contracts:

- **R — retain:** Name the contract and credible failure.
- **F — fix:** Retain the contract but repair a vacuous assertion.
- **C — consolidate:** Name the receiving owner-boundary test.
- **D — delete:** Supply every field from the candidate record in `SKILL.md`.
- **U — uncertain:** Keep it and name the missing evidence.

Inspect entry points, callers, callees, siblings, overlapping tests, history,
and CI routing before marking a test D or C.

## 4. Edit lanes

Apply one lane at a time. Keep its retained owner tests passing before moving
to the next lane. Delete obsolete test-only exports, globals, wrappers, and
dead production paths with their tests. Do not preserve aliases for removed
test-only APIs.

Do not add replacement tests that restate the deleted implementation. Record
any product defect as separate work unless the user requests its repair.

## 5. Validate

For every lane, run its smallest owner tests. Run executable or generated-file
checks that own a retained external contract. Follow AGENTS.md during edits.

After all lanes pass, run:

```sh
zig build test
git diff --check
```

Run the benchmark procedure in AGENTS.md when the change affects the JS host,
engine, or renderer.

## 6. Preservation review

Have a reviewer compare every D or C decision with the retained tests. The
review checks that no contract lost its only proof and that each negative case
reaches its intended guard.

For each restored contract, make a deliberate local mutation of the production
owner. Confirm that its retained test fails. Restore the owner byte for byte,
then rerun the focused test.

## 7. Handoff

Report:

- pinned baseline and final production, test, and support line counts;
- lanes, deleted tests, consolidated tests, and retained keepers;
- removed test-only production seams;
- preservation gaps and mutation proof;
- baseline failures and product defects;
- focused checks, full proof, and benchmark evidence actually run; and
- uncertain candidates and next steps.
