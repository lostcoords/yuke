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
    generate_with_migrations(test, migrations, queries)
        .unwrap_err()
        .to_string()
}

/// Generate from the migrations and queries, and remove the test folder before returning the result.
fn generate_with_migrations(
    test: &str,
    migrations: &[(&str, &str)],
    queries: &str,
) -> Result<yuke_sqlgen::Generated, yuke_sqlgen::Error> {
    let folder: PathBuf = std::env::temp_dir().join(format!("yuke-sqlgen-{test}"));
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
    result
}

/// Assert that `error` names the query file, `query`, and `reason`.
fn assert_names(error: &str, query: &str, reason: &str) {
    assert!(error.contains("notes.sql"), "{error}");
    assert!(error.contains(&format!("query `{query}`")), "{error}");
    assert!(error.contains(reason), "{error}");
}

#[test]
fn sql_that_sqlite_rejects_stops_generation() {
    let error = error_of("rejected", "--! broken\nSELECT missing FROM notes;");

    assert_names(&error, "broken", "no such column: missing");
}

#[test]
fn a_parameter_without_a_name_stops_generation() {
    let error = error_of(
        "unnamed",
        "--! by_position (id: i64)\nSELECT title FROM notes WHERE id = ?;",
    );

    assert_names(&error, "by_position", "parameter 1 has no name");
}

#[test]
fn a_parameter_without_an_annotation_stops_generation() {
    let error = error_of("unannotated", "--! by_id\nSELECT title FROM notes WHERE id = :id;");

    assert_names(
        &error,
        "by_id",
        "`:id` needs an annotation with its type, for example `--! by_id (id: i64)`",
    );
}

#[test]
fn a_parameter_annotation_without_a_type_stops_generation() {
    let error = error_of("untyped", "--! by_id (id)\nSELECT title FROM notes WHERE id = :id;");

    assert_names(&error, "by_id", "the parameter `id` needs a type");
}

#[test]
fn a_parameter_annotation_that_names_no_parameter_stops_generation() {
    let error = error_of("unused_parameter", "--! titles (id: i64)\nSELECT title FROM notes;");

    assert_names(&error, "titles", "the annotation `id` names no parameter");
}

#[test]
fn an_inline_row_without_a_returned_field_stops_generation() {
    let error = error_of(
        "missing_inline_field",
        "--! titles : (id)\nSELECT id, title FROM notes;",
    );

    assert_names(&error, "titles", "the column `title` has no field declaration");
    assert!(
        error.contains("Add `title` to the row declaration after `:`"),
        "{error}"
    );
}

#[test]
fn a_query_without_declared_fields_stops_generation() {
    for (test, row) in [("missing_row", ""), ("empty_row", " : ()")] {
        let error = error_of(test, &format!("--! titles{row}\nSELECT title FROM notes;"));

        assert_names(&error, "titles", "the column `title` has no field declaration");
    }
}

#[test]
fn a_returned_column_that_appears_twice_stops_generation() {
    let error = error_of(
        "duplicate_column",
        "--! titles : (title)\nSELECT title, title FROM notes;",
    );

    assert_names(&error, "titles", "the column `title` appears twice");
}

#[test]
fn complete_row_declarations_infer_types_and_match_columns_by_name() {
    let queries = "--! notes : (body?, title, id)\nSELECT id, title, body FROM notes;\n\
                   --! titles : (title, id)\nSELECT id, title FROM notes;";
    let generated = generate_with_migrations("complete_rows", &[("0001_notes.sql", SCHEMA)], queries).unwrap();

    assert_eq!(generated.queries, 2);
    for (row, expected) in [
        (
            "Notes",
            &[
                "pub(crate) id: i64,",
                "pub(crate) title: String,",
                "pub(crate) body: Option<String>,",
            ][..],
        ),
        ("Titles", &["pub(crate) id: i64,", "pub(crate) title: String,"][..]),
    ] {
        let (_, body) = generated.code.split_once(&format!("struct {row} {{\n")).unwrap();
        let (fields, _) = body.split_once("\n    }").unwrap();
        assert_eq!(fields.lines().map(str::trim).collect::<Vec<_>>(), expected, "{row}");
    }
}

#[test]
fn a_column_annotation_that_names_no_column_stops_generation() {
    let error = error_of("unused_column", "--! titles : (titel?)\nSELECT title FROM notes;");

    assert_names(&error, "titles", "the annotation `titel` names no column");
}

#[test]
fn a_column_without_a_rust_name_stops_generation() {
    let error = error_of("unnamed_column", "--! counted\nSELECT count(*) FROM notes;");

    assert_names(&error, "counted", "`AS name`");
}

#[test]
fn a_computed_column_without_a_type_stops_generation() {
    let error = error_of(
        "computed",
        "--! counted : (count)\nSELECT count(*) AS count FROM notes;",
    );

    assert_names(&error, "counted", "the column `count` needs a type");
}

#[test]
fn a_nullable_column_without_a_question_mark_stops_generation() {
    let error = error_of("nullable", "--! bodies : (body)\nSELECT body FROM notes;");

    assert_names(&error, "bodies", "the column `body` can be NULL");
    assert!(error.contains("for example `body?`"), "{error}");
}

#[test]
fn a_row_annotation_on_a_query_without_columns_stops_generation() {
    let error = error_of(
        "exec_row",
        "--! touch (id: i64) : (id?)\nUPDATE notes SET title = title WHERE id = :id;",
    );

    assert_names(&error, "touch", "the query returns no column");
}

#[test]
fn columns_after_a_colon_without_parentheses_stop_generation_at_their_line() {
    let error = error_of("bare_columns", "--! titles : Note\nSELECT title FROM notes;");

    assert!(error.contains("notes.sql: line 1"), "{error}");
    assert!(error.contains("the columns after `:` need parentheses"), "{error}");
}

#[test]
fn an_annotation_outside_the_grammar_stops_generation_at_its_line() {
    let error = error_of(
        "grammar",
        "-- Notes.\n--! by_id (id: i64\nSELECT title FROM notes WHERE id = :id;",
    );

    assert!(error.contains("notes.sql: line 2"), "{error}");
    assert!(error.contains("a `(` has no matching `)`"), "{error}");
}

#[test]
fn a_field_that_appears_twice_stops_generation_at_its_line() {
    let error = error_of("twice", "--! titles : (body?, body?: String)\nSELECT body FROM notes;");

    assert!(error.contains("notes.sql: line 1"), "{error}");
    assert!(error.contains("the field `body` appears twice"), "{error}");
}

#[test]
fn a_repeated_migration_number_stops_generation() {
    let error = error_with_migrations(
        "repeated_number",
        &[
            ("0001_notes.sql", SCHEMA),
            ("0001_tags.sql", "CREATE TABLE tags (name TEXT NOT NULL) STRICT;"),
        ],
        "--! titles : (title)\nSELECT title FROM notes;",
    );

    assert!(error.contains("0001_tags.sql"), "{error}");
    assert!(error.contains("number 1, but it is migration 2"), "{error}");
}

#[test]
fn a_gap_in_the_migration_numbers_stops_generation() {
    let error = error_with_migrations(
        "gap",
        &[
            ("0001_notes.sql", SCHEMA),
            ("0003_tags.sql", "CREATE TABLE tags (name TEXT NOT NULL) STRICT;"),
        ],
        "--! titles : (title)\nSELECT title FROM notes;",
    );

    assert!(error.contains("0003_tags.sql"), "{error}");
    assert!(error.contains("number 3, but it is migration 2"), "{error}");
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
