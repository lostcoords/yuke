# Read-state (Review) — daemon design

Status: proposal (2026-08-23). Validated by 3 independent code-grounded critiques.
Source of truth: `lib/wire/` and the session/message projections when implementation starts.
Last verified: 2026-08-31.

## Goal & scope

Make the inbox **Review / unread** state roam across one user's devices, by making
it **daemon-owned** — no cloud. A session is "Review" when it is idle and has
unread assistant content.

Fixed decisions:
- **Single-user daemon.** Read-state is session-global (no per-viewer key). Safe
  only under this invariant — see [Scope invariant](#scope-invariant).
- **Pins stay client-local** (machine-specific). Not modelled here.
- **Attention/needs-input reuses the existing `activity` state.** No new state.
- **No cloud.** Roaming works because read-state lives on the daemon that *owns*
  the session; every device is a viewer of that one authority. (Seeing an
  offline daemon's sessions is a separate cloud feature, out of scope.)

## The primitive: an assistant-message head vs a read cursor

`unread = last_read_assistant_message_id < assistant_message_id_high`

The comparator must be **assistant messages only**. Rejected alternatives:
- `seq_high` — event-allocation watermark; bumped by `run.started`,
  `config.changed`, `transcript.truncated`, etc. (`src/database/event.zig:18`).
  Would flag unread for bookkeeping the user never sees.
- `message_id_high` — the `messages` table includes `user` and `compaction`
  roles (`src/database/migrations/0001_initial.sql:134`), so the user's own input
  would mark the session unread.
- `message_count` / `updated_at_ms` — cardinality / recency, not a content
  cursor.

## Head derivation (self-heals truncation)

Derive the head from **surviving** assistant messages, not a monotonic mark:

```sql
-- assistant content head for a session
SELECT COALESCE(MAX(message_id), 0) AS assistant_message_id_high
FROM messages WHERE session_id = :id AND role = 'assistant';
```

Because truncation deletes rows, `MAX(...)` drops with them, so a session read
through the old head goes back to "no unread" automatically — no rewind reset,
no stuck Review. (Contrast: a persisted never-decreasing high-water mark would
need an explicit truncation reset. We deliberately do not use one here.)

Maintain it efficiently as messages commit/truncate rather than scanning each
list — e.g. a maintained value updated in the same write txn as the message
projection, recomputed on truncation. Keep it consistent with
`messages_apply` / truncation handling.

## Storage

```sql
-- New migration. Separate table (NOT a column on sessions): keeps read-state out
-- of the summary/summary_changed semantics; cascades on session delete.
CREATE TABLE session_read (
    session_id BLOB PRIMARY KEY CHECK (length(session_id) = 16)
        REFERENCES sessions(id) ON DELETE CASCADE,
    last_read_assistant_message_id INTEGER NOT NULL DEFAULT 0
        CHECK (last_read_assistant_message_id BETWEEN 0 AND 9007199254740991)
) STRICT, WITHOUT ROWID;
```

A missing row means `last_read = 0` (everything unread).

## Wire changes

Put the **head on the session summary** so it propagates on every live update;
put the **cursor on the list item**.

```zig
// lib/wire/misc.zig — Session summary (rides session.summary_changed,
// which carries misc.Session, so the head updates live on new messages)
assistant_message_id_high: ids.MessageId,

// lib/wire/session.zig — SessionListItem (currently {session, activity})
last_read_assistant_message_id: ids.MessageId,
```

Then `unread = item.last_read_assistant_message_id < item.session.assistant_message_id_high`.
Keep the raw pair. A derived `unread: bool` is an optional convenience; do **not**
add `unread_count` (message ids have gaps).

Regenerate `schema/wire.json` + generated artifacts from these.

## RPC

```
session.mark_read { session_id, last_read_assistant_message_id }
```
Handler, in one write transaction:
1. read the session's current assistant head `H`;
2. `stored = max(stored, min(requested, H))`  — clamp to head, monotonic;
3. if `stored` increased, emit the broadcast after commit.

Idempotent; safe under retries and out-of-order delivery.

## Broadcast

```
session.read_changed { session_id, last_read_assistant_message_id }   // ungated
```
Ungated (all connections), same delivery class as `summary_changed`. It is a
**read receipt** — acceptable while the daemon is single-user. Gate it before
distinct users can share one daemon (see below).

Note: `session.summary_changed` already carries `misc.Session`, so a new
assistant message updates `assistant_message_id_high` on every client with no
extra broadcast. `read_changed` only carries the cursor movement.

## Client changes (yuke-client, and later the TUI)

- Review predicate (replaces `updated_at_ms > lastSeen`):
  `activity idle` AND `message_count > 0` AND
  `last_read_assistant_message_id < assistant_message_id_high`
  (today: `DeviceRegistry.svelte.ts:206`).
- **Delete `inboxSeen`** (localStorage seen). 
- **Wire `session.mark_read` into the real open/focus flow.** Today
  `DeviceRegistry.markSeen` only writes localStorage and has no production caller
  (`Sidebar.svelte:75`); opening a session must now send `mark_read` with the
  current head.
- Fold `session.read_changed` in `DeviceFeed` alongside summary/activity.
- Pins unchanged. Attention unchanged.
- TUI (yuke-odin / future) gains Review for free by consuming the same fields.

## Scope invariant

Session-global read-state is correct **only while one daemon serves one user.**
`yuke-cloud` supports team + direct device sharing; once two distinct users view
one daemon, a global watermark lets one clear the other's Review, and the
ungated `read_changed` becomes a cross-user read receipt. Before that ships:
add a `principal_id` to `session_read`'s key and principal-gate `read_changed`.
The column add is a clean migration, but past global history cannot be split
back per-user — so treat it as gated on the single-user invariant.

## Out of scope / non-goals

- Cross-device visibility of an **offline** daemon's sessions (needs a cloud
  session index; metadata only, never transcripts).
- Pins, attention/needs-input model changes.
- Child (subagent) and cron sessions: excluded from the inbox already
  (`session.sql:124`, `origin IN ('root','fork')`); cron is being removed.
- `unread_count`, per-message read marks.

## Build order

1. Migration `000N_session_read.sql` + head maintenance in the message
   projection/truncation path.
2. Wire fields + `schema/wire.json` regen.
3. `session.mark_read` handler + `session.read_changed` broadcast (needs the
   session subscription/fan-out slice to exist).
4. Client: predicate swap, remove `inboxSeen`, wire `mark_read` into open/focus,
   fold `read_changed`.
