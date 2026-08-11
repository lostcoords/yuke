/*
The store package owns the daemon's SQLite database: provider credentials, the
`events` log of record, and derived per-session state.

`open` opens the single writer (`Readwrite|Create|Nomutex`), sets
`busy_timeout`, runs a `quick_check`, and validates `application_id` and
`user_version` before making a write. It accepts either this application's
database or a truly empty database, then configures WAL with
`synchronous=NORMAL` and migrates. Every failure on that path is an `Error`;
damaged, foreign, or future-versioned files are refused rather than asserted.

`Error` is a union: `Store_Error` for outcomes the store decides itself, and the
`sqlite.Result` / `sqlite.Scan_Error` a lower layer produced, kept verbatim rather
than collapsed into a store name. `or_return` lifts either into it, so a call site
propagating a failure needs no conversion. Assertions guard internal invariants instead
(a dense migration set, a live store that owns its writer, and statement ownership).

Migrations are flat numbered files under `migrations/`, embedded with `#load` and
applied forward-only; there are no down scripts. Each pending step runs in its own
`BEGIN IMMEDIATE` transaction that also writes the step's hash row and bumps `PRAGMA
user_version`, which is the applied-version record. A database whose `user_version`
exceeds the last embedded step was written by a newer daemon and is refused.

Shipped migration text is immutable. `migration_hash` records an FNV-1a of each
step's exact bytes when it is applied, and every open checks that the embedded
text still matches what the database was migrated with; a mismatch is refused
with `Migration_Drift`.

`event_append` writes the event row and the session's `seq_high` from the same
bound value inside one `BEGIN IMMEDIATE` transaction, so the log and the mark
cannot diverge; the caller supplies `seq_high + 1`. Contiguity is enforced by the
update's own `WHERE seq_high = ? - 1` guard rather than by a prior read. A session
with no registry row returns `Unknown_Session`, distinct from a replayed or gapped
seq against a real row, which returns `Seq_Conflict`; either rolls the whole
transaction back. High-water marks are read from `sessions`, never from
`MAX(events.seq)`: if rows are ever deleted, a max-row derivation would hand the
deleted numbers out again.

Id-family marks ride the durable event that records each id and advance in the
same transaction as that event. An id whose only record is a live broadcast is
deliberately unmarked: an input id between `input.queued` and the
`message.committed` that carries it, and a draft message id before it commits,
are both re-minted after a restart. That is unobservable, because the queue and
the draft do not survive one either. Marks only ever move up, so a stale value is
a no-op rather than a rewind.

`session_create` writes the registry row and its (optional) system prompt row in
one transaction: events and projected messages carry a foreign key into the
registry row, so it must exist first, and a half-created session must not be
possible.

Ownership: `Store` owns its writer connection, its prepared statements, and their
scan mappings, and is freed by `close`. The mappings resolve columns of those
statements, so `close` destroys them first. Statements are prepared once after
migrations and left clean by `reset_and_clear` or `execute`, on failing paths as
well as succeeding ones. Column borrows from `libs:bindings/sqlite` never outlive the
statement that produced them. Tagged row scans require every high-water column and
clone event text before the next step. `events_visit_after` is the only reader of
the log: each row's payload is cloned into the allocator the caller supplies, and
that clone is handed to the visitor outright — the visitor frees nothing, and the
caller reclaims every row wholesale (typically by resetting the arena backing that
allocator) once the visit ends. Persisted storage classes are validated on read as
well as constrained by the schema. Credential reads borrow the SQLite row, clone
only the selected arm, and explicitly wipe every owned secret during cleanup.
*/

package store
