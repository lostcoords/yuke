//! The generated code of the fixture runs against the fixture schema, and the committed output is current.

use std::path::{Path, PathBuf};

use yuke_sql::rusqlite::types::{FromSql, FromSqlResult, ToSqlOutput, ValueRef};
use yuke_sql::rusqlite::{self, Connection, ToSql};

#[path = "fixture/src/queries.rs"]
mod queries;

/// The id of a note. The generated code finds this domain type through `use super::*`.
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
    let generated = yuke_sqlgen::generate(&fixture().join("migrations"), &fixture().join("queries")).unwrap();
    let path = fixture().join("src/queries.rs");
    if std::fs::read_to_string(&path).ok().as_deref() != Some(generated.code.as_str()) {
        // The test writes the new output, so a run after a change of the fixture updates the file.
        std::fs::write(&path, generated.code).unwrap();
        panic!(
            "{} was out of date; it is now updated, so check the change and run the tests again",
            path.display()
        );
    }
}

#[test]
fn the_generated_queries_run_against_the_fixture_schema() {
    use queries::notes;

    let connection = Connection::open_in_memory().unwrap();
    let migration = std::fs::read_to_string(fixture().join("migrations/0001_notes.sql")).unwrap();
    connection.execute_batch(&migration).unwrap();
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
        notes::Note {
            id: NoteId(1),
            author: "ada".to_owned(),
            title: "first".to_owned(),
            body: None,
        }
    );
    let bodies: Vec<Option<String>> = notes::notes_of(&connection, "ada").map(|note| note.body).all().unwrap();
    assert_eq!(bodies, [None, Some("text".to_owned())]);
    let titled = notes::NotesTitledParams {
        stars: 0,
        title: Some("second"),
    };
    let found = notes::notes_titled(&connection, &titled)
        .map(|note| note.id)
        .all()
        .unwrap();
    assert_eq!(found, [NoteId(2)]);
    assert_eq!(notes::note_count(&connection).one().unwrap().count, 2);
    assert_eq!(notes::star_note(&connection, NoteId(2)).unwrap(), 1);
    assert_eq!(notes::stars_of(&connection, NoteId(2)).one().unwrap().stars, 1);
}
