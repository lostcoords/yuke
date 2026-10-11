# store

A SQLite store for the sessions of [`yuke-agent`](../agent). `SqliteStore::open(folder)` opens `folder/yuke.db` and
keeps a folder for each session in `folder/sessions/<id>/`, with the lock file and the blobs of the session.

## Database

- One file holds all sessions. The connection uses WAL, and a commit is durable when it returns.
- One connection runs each read and write in call order on its own thread.
- The `sessions` table holds one row for each session. The `commits` table holds one row for each engine commit. The
  `pending_inputs` table holds the inputs that no commit consumed.
- Blocks and settings are JSON. The answer facts and the turn end are columns.
- `open` loads the context from the newest replacement: its head, the blocks that it keeps, and the commits after it.

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

## Migrations and queries

The migrations are in `migrations/`, and the queries are in `queries/`. After a change, write `src/queries.rs` again:

```sh
mise exec -- cargo run -p yuke-sqlgen
```

A database at `user_version` `n` runs each migration after the first `n`. A database that a newer yuke migrated does
not open.
