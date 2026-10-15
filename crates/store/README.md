# store

A SQLite store for the sessions of [`yuke-agent`](../agent). `SqliteStore::open(folder)` opens `folder/yuke.db` and
keeps a folder for each session in `folder/sessions/<id>/`, with the lock file and the blobs of the session.

## Database

- One file holds all sessions. The connection uses WAL. A returned commit survives a crash, but on macOS not always a
  power loss (plain `fsync`).
- One connection runs each read and write in call order on its own thread.
- The `sessions` table holds one row for each session. The `events` table holds the engine commits and the settings of
  each session, numbered 1, 2, 3, and so on. The first event of a session holds its settings, and the newest settings
  event holds the current settings. The `pending_inputs`
  table holds the inputs that no commit consumed.
- Each commit and each settings change take the next event number in the same transaction, so the numbers have no gap.
- Blocks and settings are JSON. The answer facts and the turn end are columns.
- `open` loads the context from the newest replacement: its head, the blocks that it keeps, and the commits after it.
- `load(id, after)` reads the events after event number `after` (every event for `None`) and the pending inputs in one
  read transaction, so both come from one moment.

## Owner lock

`open` with `Access::Write` locks `sessions/<id>/lock`. A second writer, in this process or another one, gets
`StoreError::Owned`. The lock stays held until the `Lease` drops and each write that the lease started has ended.

## Blobs

- `put_blob` writes the bytes to `sessions/<id>/<sha256>`. The file is durable before the call returns.
- A second put of the same bytes replaces the file with equal content.
- A blob belongs to one session. The same image in two sessions is two files.
- `read_blob` reads the file synchronously, because the request encoder reads blobs synchronously.
- `delete_session` deletes the rows. Then it removes the folder of the session.
- `SqliteStore::open` removes each folder that has no session row and no held lock, for example after a crash during
  a delete.

## Fork

- `fork_session` copies the session up to the end of a completed turn: the event that the fork names, or the newest
  completed turn. A copied event keeps its number, its token usage, and its creation time. The newest copied settings
  event gives the settings of the fork. The pending inputs stay with the source.
- The blobs come before the rows, so a reader finds every blob of a fork. The fork locks its new folder and
  copies each blob file through a temporary file. Then one transaction copies the rows. On a file system with
  reflinks, such as btrfs or APFS, a copy can share the blocks of the source file.
- The fork takes no lock on the source, so a writer of the source can keep its lease during the fork.
- When the copy fails, the store deletes the rows and the folder of the fork. An error of that delete returns in
  place of the error of the copy.

## Migrations and queries

The migrations are in `migrations/`, and the queries are in `queries/`. After a change, write `src/queries.rs` again:

```sh
mise exec -- cargo run -p yuke-sqlgen
```

A database at `user_version` `n` runs each migration after the first `n`. A database that a newer yuke migrated does
not open.
