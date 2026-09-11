# A queued compaction does not survive a restart

Status: open. The `compaction` branch (`3f01217`) ships without it.
Date: 2026-09-09.

## What happens now

`session.compact` on a session with an active run does three steps in `src/engine/commands.zig`:

1. It allocates a run id. `database.event.allocRunId` raises `run_id_high` on the `sessions` row and
   commits, so the id is durable.
2. It sets `rt.pending_compaction = .{ run_id, reason }`. This field lives on the resident `Session` in
   `src/session/session.zig`. Memory holds it. Nothing writes it to SQLite.
3. It answers `{ status: "queued", run_id }`.

`turn.finishSlot` reads that field when the active run ends, and `compaction.startPending` starts the
compaction with the reserved id.

## The failure

The process can stop between step 3 and the start: a crash, a quit, or a daemon restart. The field dies
with the process. `Engine.hydrate` rebuilds the resident session from SQLite and restores the queued
inputs from `pending_inputs`, but no row states that a compaction is owed.

The result:

- The run id left the durable counter, so no later run takes that number.
- No `run.started` and no `run.done` ever carry it.
- The compaction does not run.

Nothing is corrupt. The transcript does not change, and `/compact` works again. The TUI stays consistent,
because the `pending_compaction` gauge reads the resident session, so it also forgets.

The real cost: `session.compact` is the only method that answers a run identifier for work that can
disappear. Every other run id in yuke has a durable `run.started` behind it.

## The fix

Store the intent beside the open-run triad, which already holds this shape.

1. Schema, `src/store/migrations/0001_initial.sql`. Add two nullable columns to `sessions`:
   `pending_compaction_run_id` and `pending_compaction_reason`. Add one CHECK that pairs them, as the
   file does for `open_run_id` and `open_run_kind`. Edit the migration in place, because the project is
   pre-release and migration drift is expected. Delete the local database after the edit.
2. SQL, `src/store/queries/session.sql`. Add a setter and a clear. Read the pair in `SessionSnapshot`.
   Regenerate with `zig build sqlgen`.
3. `src/engine/commands.zig`, `sessionCompact`. Allocate the run id and write the pair in ONE
   transaction. Today `compaction.reserveRun` owns its own transaction, so the answer and the record can
   separate. They must not.
4. `src/engine/compaction.zig`, `begin`. Clear the pair in the transaction that writes `run.started`.
5. `src/engine/commands.zig`, `sessionCancelRun`. Clear the pair durably, not only in memory.
6. `src/engine/Engine.zig`, `hydrate`. Restore the pair onto `resident.pending_compaction`, beside the
   queued input restore.
7. `src/engine/Engine.zig`, `repair`. Decide what a repaired tree does with a stored pending compaction.
   The simple answer: leave it, and let the existing wake path start it, as a protected input behaves.

Tests to add:

- A restart restores a queued compaction, and the run then produces its `run.started`.
- A cancel clears the stored pair, so a restart starts nothing.
- A started compaction clears the pair, so a restart never starts it twice.

Size: about 60 to 80 lines with the tests.

## The alternative

Keep the field resident and state the limit in the protocol documentation. The window is small, the
recovery is one more `/compact`, and the automatic trigger fires again when the session stays above the
high water. pi refuses a compaction under an active run with `LaneBusy` instead of a queue, and Claude
Code stores no queued compaction either.

The reason to prefer the fix: the protocol already models the queue with `CompactStatus.queued` and
`SessionActivity.pending_compaction`, so the engine should honour what it answers.
