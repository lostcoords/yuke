# sqlgen

Typed Rust for the SQLite queries of `.sql` files. `generate` runs the migrations into an in-memory database, checks
each query against that schema, and writes one module of functions for each query file. The functions return the types
of [`yuke-sql`](../sql).

## Query files

```sql
--! note_by_id (id: crate::NoteId) : (id: crate::NoteId, author, title, body?)
--- The note with this id.
SELECT id, author, title, body FROM notes WHERE id = :id;

--! insert_note (author: &str, title: &str, body?: &str)
INSERT INTO notes(author, title, body) VALUES (:author, :title, :body);
```

| Syntax | Meaning |
| --- | --- |
| `--! name (parameters) : (columns)` | A query. The parameters are optional. A query that returns columns needs a row declaration. |
| `--- text` | The doc comment of the query. |
| `name`, `name?`, `name: Type`, `name?: Type` | A field. `?` makes it an `Option`. |

- A parameter annotation is the type of the function argument, for example `&str` or `crate::NoteId`. SQLite reports
  no parameter type, so each parameter needs one.
- A type of the crate needs its full path, for example `crate::NoteId`. The generated modules import no name of their
  parent.
- A row declaration lists every returned column exactly once. It lists no column that the query does not return.
  The field order can differ from the column order in the query. A query of one column gives the value of that
  column. A query of several columns gets a row struct with the name of the query in PascalCase, for example
  `NoteById`.
- A column takes its type from its schema declaration: `INTEGER` is `i64`, `REAL` is `f64`, `TEXT` is `String`, and `BLOB` is
  `Vec<u8>`. A computed column needs a type annotation. A domain type needs a type override.
- A table column without `NOT NULL` needs `?`. Write `NOT NULL` on key columns, for example
  `id INTEGER PRIMARY KEY NOT NULL`.
- SQLite reports the table column of a result, not whether the result can be `NULL`. So the generator rejects only a
  nullable table column without `?`. Some queries return `NULL` from a `NOT NULL` column. Mark their columns with `?`:
  - an outer join (`LEFT`, `RIGHT`, `FULL`), also inside a view, a CTE, or a subquery
  - a scalar subquery without a row
  - a bare column of an aggregate over no rows
  - a compound select with a later arm that returns `NULL`, for example `UNION ALL SELECT NULL`

  A read of a `NULL` into a field that is not an `Option` fails.
- Migrations are numbered `0001_name.sql`, `0002_name.sql`, and on, with no gap and no repeat.

## Generated code

```rust
let note = queries::notes::note_by_id(&connection, id).opt()?; // Option<NoteById>
let title = queries::notes::note_by_id(&connection, id).one()?.title; // String
let params = queries::notes::InsertNoteParams { author: "ada", title: "a", body: None };
let changed = queries::notes::insert_note(&connection, &params)?; // usize
```

A query with columns returns a `Query`: pick `one`, `opt`, or `all`. A query without
columns runs at once and returns the number of changed rows. A query with more than one parameter takes a parameter
struct. The fixture in [`tests/fixture`](tests/fixture) shows a full query file and its output.

The generated file also holds `MIGRATIONS`, the SQL of each migration in number order. Each item is an `include_str!`
of a file in `migrations`, so the binary holds the SQL. The `user_version` of a database counts its applied
migrations, so a database at `user_version` `n` runs `MIGRATIONS[n..]`.

## Command

The command writes `<dir>/src/queries.rs` from `<dir>/migrations` and `<dir>/queries`. The default `<dir>` is
`crates/store`.

| Command | Result |
| --- | --- |
| `mise exec -- cargo run -p yuke-sqlgen` | Writes the file, or reports that it is up to date. |
| `mise exec -- cargo run -p yuke-sqlgen -- --check` | Writes nothing. Exits with status 1 when the file is out of date. |
| `mise exec -- cargo run -p yuke-sqlgen -- --crate crates/sqlgen/tests/fixture` | Writes the output of the fixture. |
| `mise exec -- cargo run -p yuke-sqlgen -- --help` | Shows the options and examples. |

On success, the command prints the file and its counts, for example `queries: 7`.
On failure, the command prints the error and its source chain. Query validation errors identify the file, query, and reason.
A usage error exits with status 2.

## Drift

The generated file is committed. A test compares it with a new `generate` run, so `cargo test` fails when a query file
or a migration changes without a new output. The test writes nothing. The commands above write the new output.

## Dependencies

- `rustfmt`, which formats the output with the `rustfmt.toml` of the workspace.
