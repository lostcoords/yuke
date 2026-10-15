//! Behavior tests of the query runtime against an in-memory SQLite.
#![expect(clippy::unwrap_used, reason = "a test fails by panicking")]

use yuke_sql::rusqlite::{self, Connection};
use yuke_sql::{FromRow, Query, execute};

#[derive(Debug, PartialEq)]
struct Note {
    id: i64,
    title: String,
    body: Option<String>,
}

impl FromRow for Note {
    fn from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Self> {
        Ok(Note {
            id: row.get("id")?,
            title: row.get("title")?,
            body: row.get("body")?,
        })
    }
}

/// A database with the notes `1 first` and `2 second`, both without a body.
fn notes() -> Connection {
    let connection = Connection::open_in_memory().unwrap();
    connection
        .execute_batch(
            "CREATE TABLE notes(id INTEGER PRIMARY KEY, title TEXT NOT NULL, body TEXT) STRICT;
             INSERT INTO notes(id, title) VALUES (1, 'first'), (2, 'second');",
        )
        .unwrap();
    connection
}

fn note(id: i64, title: &str) -> Note {
    Note {
        id,
        title: title.to_owned(),
        body: None,
    }
}

const BY_ID: &str = "SELECT id, title, body FROM notes WHERE id = :id";
const ALL: &str = "SELECT id, title, body FROM notes ORDER BY id";

#[test]
fn one_returns_the_row() {
    let connection = notes();

    let found = Query::<Note>::new(&connection, BY_ID, &[(":id", &2)]).one().unwrap();

    assert_eq!(found, note(2, "second"));
}

#[test]
fn one_fails_for_no_row_and_for_a_second_row() {
    let connection = notes();

    let none = Query::<Note>::new(&connection, BY_ID, &[(":id", &3)]).one();
    let two = Query::<Note>::new(&connection, ALL, &[]).one();

    assert!(matches!(none, Err(rusqlite::Error::QueryReturnedNoRows)), "{none:?}");
    assert!(
        matches!(two, Err(rusqlite::Error::QueryReturnedMoreThanOneRow)),
        "{two:?}"
    );
}

#[test]
fn opt_returns_none_for_no_row_and_fails_for_a_second_row() {
    let connection = notes();

    let none = Query::<Note>::new(&connection, BY_ID, &[(":id", &3)]).opt().unwrap();
    let two = Query::<Note>::new(&connection, ALL, &[]).opt();

    assert_eq!(none, None);
    assert!(
        matches!(two, Err(rusqlite::Error::QueryReturnedMoreThanOneRow)),
        "{two:?}"
    );
}

#[test]
fn all_returns_the_rows_in_query_order() {
    let connection = notes();

    let found = Query::<Note>::new(&connection, ALL, &[]).all().unwrap();

    assert_eq!(found, [note(1, "first"), note(2, "second")]);
}

#[test]
fn execute_returns_the_number_of_changed_rows() {
    let connection = notes();

    let changed = execute(&connection, "UPDATE notes SET body = :body", &[(":body", &"text")]).unwrap();

    assert_eq!(changed, 2);
    let found = Query::<Note>::new(&connection, BY_ID, &[(":id", &1)]).one().unwrap();
    assert_eq!(found.body.as_deref(), Some("text"));
}

#[test]
fn a_none_parameter_writes_null() {
    let connection = notes();
    let body: Option<&str> = None;

    execute(
        &connection,
        "INSERT INTO notes(id, title, body) VALUES (:id, :title, :body)",
        &[(":id", &3), (":title", &"third"), (":body", &body)],
    )
    .unwrap();

    let is_null: bool = connection
        .query_row("SELECT body IS NULL FROM notes WHERE id = 3", [], |row| row.get(0))
        .unwrap();
    assert!(is_null);
}

#[test]
fn a_preparation_error_reaches_the_read() {
    let connection = notes();

    let found = Query::<Note>::new(&connection, "SELECT id, title, body FROM missing", &[]).all();

    assert!(matches!(found, Err(rusqlite::Error::SqliteFailure(..))), "{found:?}");
}
