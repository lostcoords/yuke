//! The pragmas of a connection and the migrations of the database.

use yuke_sql::rusqlite::{Connection, TransactionBehavior};

use crate::queries::MIGRATIONS;

/// The pragmas of each open. The busy timeout comes first, so a change of the journal mode waits for another process.
/// The page size comes before the first write of a new file, because that write fixes it. The journal mode stays WAL
/// in the file. A returned commit survives a crash, but on macOS not always a power loss (plain `fsync`).
const PRAGMAS: &str = "
    PRAGMA busy_timeout = 5000;
    PRAGMA page_size = 8192;
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = FULL;
    PRAGMA foreign_keys = ON;
    PRAGMA journal_size_limit = 67108864;
";

/// Set the pragmas of `connection`, and run each migration that the database lacks. Each migration runs in its own
/// transaction with its new `user_version`.
pub(crate) fn prepare(connection: &mut Connection) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    connection.execute_batch(PRAGMAS)?;
    loop {
        // The version is read in the write transaction, so a second process that migrates the same file waits and
        // then sees the new version.
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let user_version: usize = transaction.pragma_query_value(None, "user_version", |row| row.get(0))?;
        let Some(migration) = MIGRATIONS.get(user_version) else {
            if user_version > MIGRATIONS.len() {
                // This yuke cannot read or write a newer schema safely.
                return Err(format!(
                    "the database has schema version {user_version}, and this yuke knows versions up to {}",
                    MIGRATIONS.len()
                )
                .into());
            }
            return Ok(());
        };
        transaction.execute_batch(migration)?;
        transaction.pragma_update(None, "user_version", user_version + 1)?;
        transaction.commit()?;
    }
}

#[cfg(test)]
mod tests {
    use yuke_sql::rusqlite::Connection;

    use super::{MIGRATIONS, prepare};

    #[test]
    fn a_database_of_a_newer_schema_does_not_open() {
        let mut connection = Connection::open_in_memory().unwrap();
        connection
            .pragma_update(None, "user_version", MIGRATIONS.len() + 1)
            .unwrap();

        let error = prepare(&mut connection).unwrap_err();

        assert_eq!(
            error.to_string(),
            format!(
                "the database has schema version {}, and this yuke knows versions up to {}",
                MIGRATIONS.len() + 1,
                MIGRATIONS.len()
            )
        );
        assert!(error.source().is_none());
    }

    #[test]
    fn a_new_database_gets_each_migration_once() {
        let mut connection = Connection::open_in_memory().unwrap();

        prepare(&mut connection).unwrap();
        prepare(&mut connection).unwrap();

        let user_version: usize = connection
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        assert_eq!(user_version, MIGRATIONS.len());
    }
}
