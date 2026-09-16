# Agent-tree refresh review

Production revision: `bc42d5d`. No production code changes are part of this review.

## Current work

`agents-ui.js` calls `agentRows(mainId)` after a listed session has an activity fact.
The same path handles run completion, summary changes, and removal.
`agentRows` reads the root and traverses every descendant with `allChildren`.
Every leaf also requires a child-list request to establish that it has no children.
The traversal awaits each page and subtree in sequence.
An open picker retains the rows, but does not reuse them for activity-only updates.

Each native `session.list` reads a page and its total count.
Each returned child also needs its latest outcome and its live or durable activity.
Nonresident activity requires a queue-count read. Resident activity can require a context-usage read.
These requests allocate result rows and transfer complete list items into JS.
The picker then replaces its row array and recomputes its summary.
With its filter disabled, `setSource` does not fuzzy-rank the rows.
The initial optimization target is the tree read, not the generic picker.

The native digest already merges same-session facts within a frame.
This is therefore not a claim that every text delta causes a full-tree refresh.
The issue applies when an activity fact reaches the open picker.
The JS refresh guard permits only one traversal at a time.
Any relevant event during that traversal sets a flag for another complete traversal.
It bounds concurrent work, not the total work under continuous updates.

## Request-count probe

The probe executes the production `agents-ui.js` and `allChildren` function in Node,
with mocked client reads, event registration, and picker methods.
It preserves the real async traversal, pagination, event predicates, and refresh guard.
Each client read returns fresh fixture objects. One child page has at most 100 entries.
The root is focused; a balanced fixture has at most four children per parent.

| Descendants | Shape | Calls for one activity event | Calls for a burst of 20 events |
| ---: | --- | ---: | ---: |
| 10 | Direct children | 12 | 24 |
| 100 | Direct children | 102 | 204 |
| 1,000 | Direct children | 1,011 | 2,022 |
| 1,000 | Balanced | 1,002 | 2,004 |

One activity refresh has one `sessionGet` plus all child-page requests.
The synchronous 20-event burst arrives while the first traversal awaits its root read.
It causes exactly two traversals and two source replacements in this probe.
A summary index event causes the same full traversal. An empty-facts index event causes no read.
The probe does not measure QuickJS, SQLite, native allocation costs, or latency.
It establishes request amplification, not a whole-application speedup.

Probe: `/tmp/yuke-agent-tree-probe.cjs`.
Results: `/tmp/yuke-agent-tree-probe.jsonl`.
Command: `node /tmp/yuke-agent-tree-probe.cjs`.

## Correctness constraint: digest overflow

The native dirty map holds at most 256 sessions.
If a new dirty session exceeds that bound, the native layer drops that entry and sets `dirty_overflow`.
The drain emits an index event, but does not expose the overflow flag or add the dropped facts.
The picker accepts an index event only if its facts include `session.summary_changed`.

If the retained dirty sessions are outside the displayed tree and a displayed session is dropped,
the picker can miss that session's activity update until a later accepted event.
The source trace plus the JS probe confirms that the empty-facts fallback is ignored.
A native integration regression test is still needed for the complete 257-session sequence.
Overflow can coincide with unrelated index facts, so an empty-facts check alone is insufficient.
An explicit broad-invalidation signal would avoid that ambiguity.
Its internal JS event contract must remain deliberate and documented for plugins.

## Proposed first change

For a pure activity update, read only the affected listed session through `client.sessionGet`.
Replace that row's item, retain its position and depth, and update the title and display.
Coalesce changed session ids within the existing refresh scheduler.
Let a full refresh take precedence over pending single-row reads.
Preserve full traversal for initial open, summary or structural changes, removal, and broad invalidation.
Keep run completion on the full path in the first pass to preserve outcome and ordering behavior.

Do not substitute `client.sessionActivity`: it can return null for a child without an open pane.
Do not bypass the public client object: plugin advice must remain active.
Do not parallelize every leaf query or add a second long-lived tree cache as the first fix.
The picker already owns the rows needed for a targeted update.
A one-row read still includes instruction and skill metadata; a lighter API is a later question.
Summary calculation and list selection can still cost O(N), even after reads become targeted.

## Measurement and validation next

Add a QuickJS/native benchmark before a production change.
Use direct-child and balanced trees at 10, 100, and 1,000 descendants.
Separate initial load, isolated activity updates, event bursts, and structural refreshes.
Include both resident and nonresident children. Seed the tree outside the measured work.
Count client requests, native allocation/free calls and bytes, resize/remap attempts,
live/peak bytes, UI work, and latency in separate metrics and non-metrics runs.

Checks must cover selection, order, summary counts, last-run labels, child pagination,
plugin advice, removal during a read, close during a refresh, and updates during a full traversal.
Add the native overflow regression case before a targeted refresh could hide that invalidation gap.
The current analysis does not justify a protocol-wide tree endpoint or a SQL rewrite.
