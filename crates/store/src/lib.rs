//! A SQLite [`Store`](yuke_agent::Store) for the sessions of `yuke-agent`. [`SqliteStore`] keeps all sessions in one
//! database file. Each session has a folder with its lock file and its blobs. The queries come from `yuke-sqlgen`:
//! run `mise exec -- cargo run -p yuke-sqlgen` after a change of `migrations/` or `queries/`.

mod context;
mod files;
// Clippy accepts `use super::*` in a test build, so the expectation holds only outside tests.
#[cfg_attr(
    not(test),
    expect(
        clippy::wildcard_imports,
        reason = "the generated code finds the column types of the crate through `use super::*`"
    )
)]
mod queries;
mod schema;
mod store;

use serde::de::DeserializeOwned;
use yuke_sql::rusqlite::types::{FromSql, FromSqlError, FromSqlResult, ValueRef};

pub use store::SqliteStore;

/// A column that holds a value as JSON text. Only a read decodes through this type. A write binds the text that the
/// store makes before it queues the write.
#[derive(Debug, Clone, PartialEq)]
struct Json<T>(T);

impl<T: DeserializeOwned> FromSql for Json<T> {
    fn column_result(value: ValueRef<'_>) -> FromSqlResult<Self> {
        serde_json::from_str(value.as_str()?)
            .map(Json)
            .map_err(|error| FromSqlError::Other(Box::new(error)))
    }
}
