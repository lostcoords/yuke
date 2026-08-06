package sqlgen

import "core:testing"

@(test)
test_parse_queries_reads_header_annotations_and_body :: proc(t: ^testing.T) {
    source := `-- name: Get_Widget :one
-- Prose that must not be mistaken for a field.
-- id: wire.Widget_Id!
-- label: string
SELECT id, label FROM widgets WHERE id = :id;
`
    defs, ok := parse_queries(source)
    defer query_defs_destroy(defs)
    testing.expect(t, ok)
    testing.expect_value(t, len(defs), 1)

    def := defs[0]
    testing.expect_value(t, def.name, "Get_Widget")
    testing.expect_value(t, def.cardinality, Cardinality.One)
    testing.expect_value(t, def.sql, "SELECT id, label FROM widgets WHERE id = :id;")
    testing.expect_value(t, len(def.fields), 2)
    testing.expect_value(t, def.fields[0].name, "id")
    testing.expect_value(t, def.fields[0].odin_type, "wire.Widget_Id")
    testing.expect(t, def.fields[0].required, "a `!`-suffixed annotation is required")
    testing.expect_value(t, def.fields[1].name, "label")
    testing.expect_value(t, def.fields[1].odin_type, "string")
    testing.expect(t, !def.fields[1].required, "an unsuffixed annotation defaults to optional")
}

@(test)
test_parse_queries_reads_multiple_blocks_in_one_file :: proc(t: ^testing.T) {
    source := `-- name: First :exec
-- id: wire.Widget_Id!
DELETE FROM widgets WHERE id = :id;

-- name: Second :many
SELECT 1;
`
    defs, ok := parse_queries(source)
    defer query_defs_destroy(defs)
    testing.expect(t, ok)
    testing.expect_value(t, len(defs), 2)
    testing.expect_value(t, defs[0].name, "First")
    testing.expect_value(t, defs[0].cardinality, Cardinality.Exec)
    testing.expect_value(t, defs[1].name, "Second")
    testing.expect_value(t, defs[1].cardinality, Cardinality.Many)
    testing.expect_value(t, len(defs[1].fields), 0)
}

@(test)
test_parse_queries_rejects_an_unknown_cardinality :: proc(t: ^testing.T) {
    _, ok := parse_queries("-- name: Bad :nope\nSELECT 1;\n")
    testing.expect(t, !ok, "an unrecognized cardinality marker is a parse error")
}

@(test)
test_parse_queries_rejects_a_header_with_no_body :: proc(t: ^testing.T) {
    _, ok := parse_queries("-- name: Empty :exec\n")
    testing.expect(t, !ok, "a query with no SQL body is a parse error")
}

@(test)
test_parse_field_requires_a_bare_identifier :: proc(t: ^testing.T) {
    _, prose_ok := parse_field("-- Contiguity lives in the update predicate: a gap matches nothing.")
    testing.expect(t, !prose_ok, "a multi-word key before the colon is prose, not a field")

    _, backtick_ok := parse_field("-- One `:seq` feeds both sides, so the two never drift.")
    testing.expect(t, !backtick_ok, "a colon inside backticks is not a field delimiter")

    field, ok := parse_field("-- seq: wire.Seq!")
    testing.expect(t, ok)
    testing.expect_value(t, field.name, "seq")
    testing.expect_value(t, field.odin_type, "wire.Seq")
    testing.expect(t, field.required)
}

@(test)
test_is_identifier_rejects_non_identifiers :: proc(t: ^testing.T) {
    testing.expect(t, is_identifier("session_id"))
    testing.expect(t, is_identifier("_private"))
    testing.expect(t, !is_identifier(""))
    testing.expect(t, !is_identifier("1"))
    testing.expect(t, !is_identifier("has space"))
    testing.expect(t, !is_identifier("Struct-only"))
}
