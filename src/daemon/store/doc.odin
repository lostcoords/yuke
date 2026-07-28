/*
The store package owns the daemon's SQLite database: the `events` log of record
and the derived per-session state written in the same transaction.

`open` opens the single writer (`Readwrite|Create|Nomutex`), sets
`busy_timeout`, runs a `quick_check`, and validates `application_id` and
`user_version` before making a write. It accepts either this application's
database or a truly empty database, then configures WAL with
`synchronous=NORMAL` and migrates. Every failure on that path is an `Error`;
damaged, foreign, or future-versioned files are refused rather than asserted.
Assertions guard internal invariants instead (a dense migration set, a live
store that owns its writer, and statement ownership).

Migrations are flat numbered files under `migrations/`, embedded with `#load` and
applied forward-only — there are no down scripts, and rolling back a shipped
daemon means shipping the older binary. Each pending step runs in its own
`BEGIN IMMEDIATE` transaction that also writes the step's hash row and bumps
`PRAGMA user_version`, which is the applied-version record. Migration 1 claims
the SQLite header application id in that same transaction. A database whose
`user_version` exceeds the last embedded step was written by a newer daemon and
is refused. The exact v1 schema from commit 1501c4a1 is the sole headerless
legacy form accepted; migration 2 claims it transactionally.

Shipped migration text is immutable. `migration_hash` records an FNV-1a of each
step's exact bytes when it is applied, and every open checks that the embedded
text still matches what the database was migrated with; a mismatch is refused
with `Migration_Drift`, not asserted, since it is a fact about an on-disk
database rather than our own runtime state.

`event_append` writes the event row and the session's `seq_high` from the same
bound value inside one `BEGIN IMMEDIATE` transaction, so the log and the mark
cannot diverge; the caller supplies `seq_high + 1`. Contiguity is enforced by the
update's own `WHERE seq_high = ? - 1` guard rather than by a prior read, and a
replayed or gapped seq rolls the whole transaction back (`Constraint`,
`Seq_Conflict`). High-water marks are read from `session_meta`, never from
`MAX(events.seq)`: if rows are ever deleted, a max-row derivation would hand the
deleted numbers out again.

Id families rise with `bump_ids` or ride an event append: some ids are minted
inside a durable event, others outside one, yet none may be reused after a
restart. Marks only ever move up, so a stale bump is a no-op rather than a
rewind.

Ownership: `Store` owns its writer connection, its prepared statements, and is
freed by `close`. Statements are prepared once after migrations and reused
via `reset`, whose return code reports the preceding step; every reuse also
clears bindings, including partial bind failures. Column borrows from
`libs:sqlite` never outlive the statement that produced them. Single-value
queries clone text into the temp allocator, while `events_after` returns an
owned dynamic array carrying the caller's allocator, released with
`events_destroy`. Persisted storage classes and numeric ranges are validated on
read as well as constrained by the schema.
*/

package store
