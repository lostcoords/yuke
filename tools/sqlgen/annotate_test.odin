package sqlgen

import "core:testing"

FIXTURE_DDL :: `CREATE TABLE sessions (
    id           BLOB PRIMARY KEY CHECK (typeof(id) = 'blob' AND length(id) = 16), -- wire.Session_Id
    workspace_id BLOB NOT NULL    CHECK (typeof(workspace_id) = 'blob' AND length(workspace_id) = 16), -- wire.Workspace_Id
    title        TEXT NOT NULL CHECK (typeof(title) = 'text' AND length(title) <= 256),
    seq_high     INTEGER NOT NULL DEFAULT 0 CHECK (seq_high BETWEEN 0 AND 9007199254740991),
    CHECK (typeof(title) = 'text')
) WITHOUT ROWID;

CREATE TABLE session_configs (
    session_id BLOB NOT NULL -- wire.Session_Id
        CHECK (typeof(session_id) = 'blob' AND length(session_id) = 16)
);
`

@(test)
test_column_annotation_finds_the_trailing_type_comment :: proc(t: ^testing.T) {
    odin_type, found := column_annotation(FIXTURE_DDL, "sessions", "id")
    testing.expect(t, found, "id carries an annotation")
    testing.expect_value(t, odin_type, "wire.Session_Id")

    odin_type, found = column_annotation(FIXTURE_DDL, "sessions", "workspace_id")
    testing.expect(t, found, "workspace_id carries an annotation")
    testing.expect_value(t, odin_type, "wire.Workspace_Id")
}

@(test)
test_column_annotation_is_absent_for_a_plain_column :: proc(t: ^testing.T) {
    _, found := column_annotation(FIXTURE_DDL, "sessions", "title")
    testing.expect(t, !found, "title has no trailing comment")
}

@(test)
test_column_annotation_does_not_match_a_name_prefix :: proc(t: ^testing.T) {
    // `seq_high` must not be found via a prefix match against some other `seq*` column;
    // conversely, searching for `id` must not match inside `workspace_id`'s line.
    _, found := column_annotation(FIXTURE_DDL, "sessions", "work")
    testing.expect(t, !found, "a column name must match a whole identifier, not a prefix of one")
}

@(test)
test_column_annotation_is_scoped_to_its_own_table :: proc(t: ^testing.T) {
    // `session_id` in `session_configs` is annotated; the same column name is absent
    // from `sessions`, whose block must not leak into the search.
    _, found := column_annotation(FIXTURE_DDL, "sessions", "session_id")
    testing.expect(t, !found, "session_id is not a column of sessions")

    odin_type, found_in_configs := column_annotation(FIXTURE_DDL, "session_configs", "session_id")
    testing.expect(t, found_in_configs, "session_id is annotated in session_configs")
    testing.expect_value(t, odin_type, "wire.Session_Id")
}

@(test)
test_column_annotation_reports_absent_for_an_unknown_table :: proc(t: ^testing.T) {
    _, found := column_annotation(FIXTURE_DDL, "nope", "id")
    testing.expect(t, !found, "a table that never appears in the source has nothing to find")
}
