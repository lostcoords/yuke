# store

A SQLite store for the sessions of [`yuke-agent`](../agent). `SqliteStore::open(folder)` opens `folder/yuke.db` and
keeps the owner locks in `folder/locks/`.

## Database

- One file holds all sessions. The connection uses WAL, and a commit is durable when it returns.
- One connection runs each read and write in call order on its own thread.
- The `sessions` table holds one row for each session. The `commits` table holds one row for each engine commit. The
  `pending_inputs` table holds the inputs that no commit consumed.
- Blocks and settings are JSON. The answer facts and the turn end are columns.
- `open` loads the context from the newest replacement: its head, the blocks that it keeps, and the commits after it.

## Owner lock

`open` with `Access::Write` locks `locks/<id>.lock`. A second writer, in this process or another one, gets
`StoreError::Owned`. The lock stays held until the `Lease` drops and each write that the lease started has ended.

## Migrations and queries

The migrations are in `migrations/`, and the queries are in `queries/`. After a change, write `src/queries.rs` again:

```sh
cargo run -p yuke-sqlgen
```

A database at `user_version` `n` runs each migration after the first `n`. A database that a newer yuke migrated does
not open.
