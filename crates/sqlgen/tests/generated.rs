//! The generated code of the fixture runs against the fixture schema, and the committed output is current.
#![expect(clippy::unwrap_used, reason = "a test fails by panicking")]

use std::path::{Path, PathBuf};

use yuke_sql::rusqlite::types::{FromSql, FromSqlResult, ToSqlOutput, ValueRef};
use yuke_sql::rusqlite::{self, Connection, ToSql};

#[path = "fixture/src/queries.rs"]
mod queries;

/// The id of a note. The query annotations name this domain type as `crate::NoteId`.
#[derive(Debug, Clone, Copy, PartialEq)]
struct NoteId(i64);

impl ToSql for NoteId {
    fn to_sql(&self) -> rusqlite::Result<ToSqlOutput<'_>> {
        self.0.to_sql()
    }
}

impl FromSql for NoteId {
    fn column_result(value: ValueRef<'_>) -> FromSqlResult<Self> {
        i64::column_result(value).map(NoteId)
    }
}

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixture")
}

#[test]
fn the_committed_fixture_output_is_current() {
    let generated = yuke_sqlgen::generate(&fixture()).unwrap();
    let committed = std::fs::read_to_string(fixture().join("src/queries.rs")).unwrap();

    assert!(
        committed == generated.code,
        "tests/fixture/src/queries.rs is out of date. Run `cargo run -p yuke-sqlgen -- --crate \
         crates/sqlgen/tests/fixture` to update it."
    );
}

/// An in-memory database with each migration of `MIGRATIONS`.
fn migrated() -> Connection {
    let connection = Connection::open_in_memory().unwrap();
    for migration in queries::MIGRATIONS {
        connection.execute_batch(migration).unwrap();
    }
    connection
}

#[test]
fn migrations_hold_each_migration_file_in_number_order() {
    let files: Vec<String> = ["0001_notes.sql", "0002_pins.sql", "0003_tags.sql"]
        .iter()
        .map(|name| std::fs::read_to_string(fixture().join("migrations").join(name)).unwrap())
        .collect();

    assert_eq!(queries::MIGRATIONS, files);
}

#[test]
fn a_returning_query_returns_its_typed_row() {
    let connection = migrated();
    let params = queries::notes::AddNoteParams {
        author: "ada",
        title: "first",
    };

    let added = queries::notes::add_note(&connection, &params).one().unwrap();

    assert_eq!(
        added,
        queries::notes::AddNote {
            id: NoteId(1),
            pinned: 0,
        }
    );
    let title = queries::notes::note_by_id(&connection, NoteId(1)).one().unwrap().title;
    assert_eq!(title, "first");
}

// The schema column `tags.name` is `NOT NULL`, but the join gives `NULL` for a note without a tag.
#[test]
fn an_optional_outer_join_field_reads_an_unmatched_row_as_none() {
    let connection = migrated();
    for title in ["tagged", "untagged"] {
        let params = queries::notes::AddNoteParams { author: "ada", title };
        queries::notes::add_note(&connection, &params).one().unwrap();
    }
    connection
        .execute("INSERT INTO tags(note, name) VALUES (1, 'red')", [])
        .unwrap();

    let rows = queries::notes::tagged_titles(&connection).all().unwrap();

    assert_eq!(
        rows,
        [
            queries::notes::TaggedTitles {
                title: "tagged".to_owned(),
                tag: Some("red".to_owned()),
            },
            queries::notes::TaggedTitles {
                title: "untagged".to_owned(),
                tag: None,
            },
        ]
    );
}

#[test]
fn the_generated_queries_run_against_the_fixture_schema() {
    use queries::notes;

    let connection = migrated();
    let first = notes::InsertNoteParams {
        author: "ada",
        title: "first",
        body: None,
    };
    let second = notes::InsertNoteParams {
        author: "ada",
        title: "second",
        body: Some("text"),
    };

    assert_eq!(notes::insert_note(&connection, &first).unwrap(), 1);
    notes::insert_note(&connection, &second).unwrap();

    assert_eq!(
        notes::note_by_id(&connection, NoteId(1)).one().unwrap(),
        notes::NoteById {
            id: NoteId(1),
            author: "ada".to_owned(),
            title: "first".to_owned(),
            body: None,
        }
    );
    let bodies: Vec<Option<String>> = notes::notes_of(&connection, "ada")
        .all()
        .unwrap()
        .into_iter()
        .map(|note| note.body)
        .collect();
    assert_eq!(bodies, [None, Some("text".to_owned())]);
    let titled = notes::NotesTitledParams {
        stars: 0,
        title: Some("second"),
    };
    let found: Vec<NoteId> = notes::notes_titled(&connection, &titled)
        .all()
        .unwrap()
        .into_iter()
        .map(|note| note.id)
        .collect();
    assert_eq!(found, [NoteId(2)]);
    assert_eq!(notes::note_count(&connection).one().unwrap(), 2);
    assert_eq!(notes::star_note(&connection, NoteId(2)).unwrap(), 1);
    assert_eq!(notes::stars_of(&connection, NoteId(2)).one().unwrap(), 1);
}
