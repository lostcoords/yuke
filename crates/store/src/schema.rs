//! The pragmas of a connection and the migrations of the database.

use yuke_sql::rusqlite::{Connection, OptionalExtension, TransactionBehavior};

/// The pragmas of each open. The busy timeout comes first, so a change of the journal mode waits for another process.
/// The page size comes before the first write of a new file, because that write fixes it. The journal mode stays WAL
/// in the file. A returned commit survives a crash, but on macOS not always a power loss (plain `fsync`).
const PRAGMAS: &str = "
    PRAGMA busy_timeout = 5000;
    PRAGMA page_size = 8192;
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = FULL;
    PRAGMA journal_size_limit = 67108864;
";

/// The `application_id` of a yuke database: the ASCII bytes of `yuke`. The first migration sets it.
const APPLICATION_ID: i32 = 0x7975_6b65;

/// Set the pragmas of `connection`, and run each of `migrations` that the database lacks. Each migration runs in its
/// own transaction with its new `user_version`.
pub(crate) fn prepare(
    connection: &mut Connection,
    migrations: &[&str],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    connection.execute_batch(PRAGMAS)?;
    // A migration that rebuilds a table drops the old table. With foreign keys on, the drop deletes each row that
    // refers to the old table. The pragma has no effect in a transaction, so it comes before the migrations.
    connection.pragma_update(None, "foreign_keys", false)?;
    loop {
        // The version is read in the write transaction, so a second process that migrates the same file waits and
        // then sees the new version.
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let user_version: usize = transaction.pragma_query_value(None, "user_version", |row| row.get(0))?;
        let application_id: i32 = transaction.pragma_query_value(None, "application_id", |row| row.get(0))?;
        // A new database has neither a version nor an id. Another program can set its own id without a version.
        if application_id != APPLICATION_ID && (application_id != 0 || user_version > 0) {
            return Err(
                "the database is not a yuke database or comes from a development version of yuke; use a fresh state \
                 directory"
                    .into(),
            );
        }
        let Some(migration) = migrations.get(user_version) else {
            if user_version > migrations.len() {
                // This yuke cannot read or write a newer schema safely.
                return Err(format!(
                    "the database has schema version {user_version}, and this yuke knows versions up to {}",
                    migrations.len()
                )
                .into());
            }
            break;
        };
        transaction.execute_batch(migration)?;
        // With foreign keys off, a migration can leave a row that refers to a missing row. An early return drops the
        // transaction, and the drop rolls the migration back.
        let broken: Option<String> = transaction
            .query_row(r#"SELECT "table" FROM pragma_foreign_key_check LIMIT 1"#, [], |row| {
                row.get(0)
            })
            .optional()?;
        if let Some(table) = broken {
            return Err(format!(
                "migration {} leaves a row in {table} that refers to a missing row, so the database stays at version \
                 {user_version}",
                user_version + 1
            )
            .into());
        }
        transaction.pragma_update(None, "user_version", user_version + 1)?;
        transaction.pragma_update(None, "application_id", APPLICATION_ID)?;
        transaction.commit()?;
    }
    connection.pragma_update(None, "foreign_keys", true)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use yuke_sql::rusqlite::Connection;

    use super::{APPLICATION_ID, prepare};
    use crate::queries::MIGRATIONS;

    /// A migration that rebuilds the sessions table, as a change of a column or a constraint does. The events refer
    /// only to the key.
    const REBUILD_SESSIONS: &str = "
        CREATE TABLE sessions_new (id BLOB PRIMARY KEY NOT NULL) STRICT;
        INSERT INTO sessions_new SELECT id FROM sessions;
        DROP TABLE sessions;
        ALTER TABLE sessions_new RENAME TO sessions;
    ";

    /// The number of rows in `table`.
    fn rows(connection: &Connection, table: &str) -> i64 {
        connection
            .query_row(&format!("SELECT count(*) FROM {table}"), [], |row| row.get(0))
            .unwrap()
    }

    /// A database with all migrations, and one session with one event.
    fn database_with_a_session() -> Connection {
        let mut connection = Connection::open_in_memory().unwrap();
        prepare(&mut connection, MIGRATIONS).unwrap();
        connection
            .execute_batch(
                "INSERT INTO sessions(id, prompt, settings) VALUES (x'01', '[]', '{}');
                 INSERT INTO events(session_id, seq, kind, settings) VALUES (x'01', 1, 'settings', '{}');",
            )
            .unwrap();
        connection
    }

    // The rebuild must keep the events, and a delete after the migrations must still delete them.
    #[test]
    fn a_migration_that_rebuilds_a_table_keeps_the_rows_that_refer_to_it() {
        let mut connection = database_with_a_session();
        let migrations = [MIGRATIONS, &[REBUILD_SESSIONS]].concat();

        prepare(&mut connection, &migrations).unwrap();

        assert_eq!(rows(&connection, "events"), 1);
        connection.execute_batch("DELETE FROM sessions").unwrap();
        assert_eq!(rows(&connection, "events"), 0);
    }

    #[test]
    fn a_migration_that_leaves_a_reference_to_a_missing_row_changes_nothing() {
        let mut connection = database_with_a_session();
        let migrations = [MIGRATIONS, &["DELETE FROM sessions"]].concat();

        let error = prepare(&mut connection, &migrations).unwrap_err();

        assert_eq!(
            error.to_string(),
            format!(
                "migration {} leaves a row in events that refers to a missing row, so the database stays at version {}",
                MIGRATIONS.len() + 1,
                MIGRATIONS.len()
            )
        );
        assert_eq!(rows(&connection, "sessions"), 1);
    }

    #[test]
    fn a_database_of_a_newer_schema_does_not_open() {
        let mut connection = Connection::open_in_memory().unwrap();
        connection
            .pragma_update(None, "application_id", APPLICATION_ID)
            .unwrap();
        connection
            .pragma_update(None, "user_version", MIGRATIONS.len() + 1)
            .unwrap();

        let error = prepare(&mut connection, MIGRATIONS).unwrap_err();

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

    // A development version of yuke set a version and no id. Another program can set its own id and no version.
    #[test]
    fn a_database_of_another_program_or_a_development_version_does_not_open() {
        for pragmas in ["PRAGMA user_version = 1;", "PRAGMA application_id = 42;"] {
            let mut connection = Connection::open_in_memory().unwrap();
            connection.execute_batch(pragmas).unwrap();

            let error = prepare(&mut connection, MIGRATIONS).unwrap_err();

            assert_eq!(
                error.to_string(),
                "the database is not a yuke database or comes from a development version of yuke; use a fresh \
                 state directory"
            );
        }
    }

    #[test]
    fn a_new_database_gets_each_migration_once_and_the_yuke_application_id() {
        let mut connection = Connection::open_in_memory().unwrap();

        prepare(&mut connection, MIGRATIONS).unwrap();
        prepare(&mut connection, MIGRATIONS).unwrap();

        let user_version: usize = connection
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        assert_eq!(user_version, MIGRATIONS.len());
        let application_id: i32 = connection
            .pragma_query_value(None, "application_id", |row| row.get(0))
            .unwrap();
        assert_eq!(application_id, APPLICATION_ID);
    }
}
