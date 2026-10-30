//! Each check of the generator stops a bad query file. A query error names the file, the query, and the reason.
#![expect(clippy::unwrap_used, reason = "a test fails by panicking")]

use std::path::PathBuf;

const SCHEMA: &str = "CREATE TABLE notes (
    id INTEGER PRIMARY KEY NOT NULL,
    title TEXT NOT NULL,
    body TEXT
) STRICT;";

/// Generate from a schema of notes and the query file `notes.sql` with `queries`, and return the error text.
fn error_of(test: &str, queries: &str) -> String {
    error_with_migrations(test, &[("0001_notes.sql", SCHEMA)], queries)
}

/// Generate from the `migrations`, each a file name and its SQL, and the query file `notes.sql` with `queries`, and
/// return the error text.
fn error_with_migrations(test: &str, migrations: &[(&str, &str)], queries: &str) -> String {
    // Two runs of the tests at one time get their own folders.
    let folder: PathBuf = std::env::temp_dir().join(format!("yuke-sqlgen-{test}-{}", std::process::id()));
    // A panic in an earlier run can leave the folder, so its old files go first.
    match std::fs::remove_dir_all(&folder) {
        Ok(()) => {}
        Err(error) => assert_eq!(error.kind(), std::io::ErrorKind::NotFound, "{error}"),
    }
    std::fs::create_dir_all(folder.join("migrations")).unwrap();
    std::fs::create_dir_all(folder.join("queries")).unwrap();
    for (name, sql) in migrations {
        std::fs::write(folder.join("migrations").join(name), sql).unwrap();
    }
    std::fs::write(folder.join("queries/notes.sql"), queries).unwrap();
    let result = yuke_sqlgen::generate(&folder);
    std::fs::remove_dir_all(&folder).unwrap();
    result.unwrap_err().to_string()
}

#[test]
fn invalid_queries_report_the_file_query_and_reason() {
    for (index, (query, reason)) in [
        ("--! checked\nSELECT missing FROM notes;", "no such column: missing"),
        (
            "--! checked (id: i64)\nSELECT title FROM notes WHERE id = ?;",
            "parameter 1 has no name",
        ),
        (
            "--! checked\nSELECT title FROM notes WHERE id = :id;",
            "the parameter `:id` needs an annotation with its type",
        ),
        (
            "--! checked (id)\nSELECT title FROM notes WHERE id = :id;",
            "the parameter `id` needs a type",
        ),
        (
            "--! checked (id: i64)\nSELECT title FROM notes;",
            "the annotation `id` names no parameter",
        ),
        (
            "--! checked : (id)\nSELECT id, title FROM notes;",
            "the column `title` has no field declaration",
        ),
        (
            "--! checked\nSELECT title FROM notes;",
            "the column `title` has no field declaration",
        ),
        (
            "--! checked : (title)\nSELECT title, title FROM notes;",
            "the column `title` appears twice",
        ),
        (
            "--! checked : (titel?)\nSELECT title FROM notes;",
            "the annotation `titel` names no column",
        ),
        ("--! checked\nSELECT count(*) FROM notes;", "`AS name`"),
        (
            "--! checked : (count)\nSELECT count(*) AS count FROM notes;",
            "the column `count` needs a type",
        ),
        (
            "--! checked : (body)\nSELECT body FROM notes;",
            "the column `body` can be NULL",
        ),
        (
            "--! checked (id: i64) : (id?)\nUPDATE notes SET title = title WHERE id = :id;",
            "the query returns no column",
        ),
    ]
    .into_iter()
    .enumerate()
    {
        let error = error_of(&format!("invalid-query-{index}"), query);

        assert!(error.contains("notes.sql: query `checked`:"), "{query}\n{error}");
        assert!(error.contains(reason), "{query}\nexpected: {reason}\n{error}");
    }
}

#[test]
fn invalid_annotations_report_the_file_line_and_reason() {
    for (index, (query, location, reason)) in [
        (
            "--! titles : Note\nSELECT title FROM notes;",
            "notes.sql: line 1",
            "the columns after `:` need parentheses",
        ),
        (
            "-- Notes.\n--! by_id (id: i64\nSELECT title FROM notes WHERE id = :id;",
            "notes.sql: line 2",
            "a `(` has no matching `)`",
        ),
        (
            "--! titles : (body?, body?: String)\nSELECT body FROM notes;",
            "notes.sql: line 1",
            "the field `body` appears twice",
        ),
    ]
    .into_iter()
    .enumerate()
    {
        let error = error_of(&format!("invalid-annotation-{index}"), query);

        assert!(error.contains(location), "{query}\n{error}");
        assert!(error.contains(reason), "{query}\nexpected: {reason}\n{error}");
    }
}

#[test]
fn migration_numbers_reject_repeats_and_gaps() {
    for (file, reason) in [
        ("0001_tags.sql", "number 1, but it is migration 2"),
        ("0003_tags.sql", "number 3, but it is migration 2"),
    ] {
        let error = error_with_migrations(
            "migration-number",
            &[
                ("0001_notes.sql", SCHEMA),
                (file, "CREATE TABLE tags (name TEXT NOT NULL) STRICT;"),
            ],
            "--! titles : (title)\nSELECT title FROM notes;",
        );

        assert!(error.contains(file), "{error}");
        assert!(error.contains(reason), "expected: {reason}\n{error}");
    }
}

#[test]
fn a_migration_name_without_a_number_stops_generation() {
    let error = error_with_migrations(
        "unnumbered",
        &[("notes.sql", SCHEMA)],
        "--! titles : (title)\nSELECT title FROM notes;",
    );

    assert!(error.contains("starts with its number and `_`"), "{error}");
}
