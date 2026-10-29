//! Behavior tests of the query runtime against an in-memory SQLite.

use yuke_sql::Query;
use yuke_sql::rusqlite::{self, Connection};

#[test]
fn one_fails_for_no_row_and_for_a_second_row() {
    let connection = Connection::open_in_memory().unwrap();

    let none = Query::new(&connection, "SELECT 1 WHERE 0", &[], |row| row.get::<_, i64>(0)).one();
    let two = Query::new(&connection, "SELECT 1 UNION ALL SELECT 2", &[], |row| {
        row.get::<_, i64>(0)
    })
    .one();

    assert!(matches!(none, Err(rusqlite::Error::QueryReturnedNoRows)), "{none:?}");
    assert!(
        matches!(two, Err(rusqlite::Error::QueryReturnedMoreThanOneRow)),
        "{two:?}"
    );
}

#[test]
fn opt_returns_none_for_no_row_and_fails_for_a_second_row() {
    let connection = Connection::open_in_memory().unwrap();

    let none = Query::new(&connection, "SELECT 1 WHERE 0", &[], |row| row.get::<_, i64>(0))
        .opt()
        .unwrap();
    let two = Query::new(&connection, "SELECT 1 UNION ALL SELECT 2", &[], |row| {
        row.get::<_, i64>(0)
    })
    .opt();

    assert_eq!(none, None);
    assert!(
        matches!(two, Err(rusqlite::Error::QueryReturnedMoreThanOneRow)),
        "{two:?}"
    );
}

#[test]
fn a_preparation_error_reaches_the_read() {
    let connection = Connection::open_in_memory().unwrap();

    let found = Query::new(&connection, "SELECT id FROM missing", &[], |row| row.get::<_, i64>(0)).all();

    assert!(matches!(found, Err(rusqlite::Error::SqliteFailure(..))), "{found:?}");
}
