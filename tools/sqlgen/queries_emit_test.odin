package sqlgen

import "core:strings"
import "core:testing"

import "tools:gen"

@(test)
test_generate_queries_emits_shape_and_query_structs :: proc(t: ^testing.T) {
    columns_by_table := make(map[string][]Column)
    defer delete(columns_by_table)
    columns_by_table["widgets"] = []Column{{name = "id", type = "BLOB", not_null = true}}
    sources := map[string]string{}
    shapes := []Shape{{table = "widgets", name = "Widget_Params"}}

    resolved := []Resolved_Query {
        {
            def = Query_Def{name = "Advance_Seq", cardinality = .Exec},
            params = []Resolved_Field{{name = "a", odin_type = "wire.Seq", required = true}},
        },
        {
            def = Query_Def{name = "Get_Many", cardinality = .Many},
            row = []Resolved_Field{{name = "a", odin_type = "u64", required = true}},
        },
    }

    d: gen.Diags
    defer gen.diags_destroy(&d)

    data, ok := generate_queries(shapes, columns_by_table, sources, resolved, &d)
    defer delete(data)
    testing.expect(t, ok)
    testing.expect(t, !gen.diags_failed(&d))

    text := string(data)
    testing.expect(t, strings.contains(text, "package queries"))
    testing.expect(t, strings.contains(text, "Widget_Params :: struct {"), "a schema shape's struct is emitted")
    testing.expect(t, strings.contains(text, "Advance_Seq_Params :: struct {"), "a query's Params struct is emitted")
    testing.expect(t, strings.contains(text, "Get_Many_Row :: struct {"), "a query's Row struct is emitted")
    testing.expect(
        t,
        strings.contains(text, "get_many: sqlite.Reader(Get_Many_Params, Get_Many_Row),"),
        "a query with a row is registered as a Reader",
    )
    testing.expect(
        t,
        strings.contains(text, "advance_seq: sqlite.Bind_Mapping(Advance_Seq_Params),"),
        "a query with no row is registered as a Bind_Mapping",
    )
    testing.expect(
        t,
        strings.contains(text, "advance_seq :: proc(q: ^Queries, params_in: Advance_Seq_Params) -> sqlite.Result {"),
        "an :exec query gets a generated wrapper taking ^Queries, not ^Store",
    )
    testing.expect(
        t,
        strings.contains(
            text,
            "get_many :: proc(q: ^Queries, params_in: Get_Many_Params, allocator := context.allocator) -> ([]Get_Many_Row, sqlite.Error) {",
        ),
        "a :many query gets a generated wrapper returning the raw sqlite.Error",
    )
}

@(test)
test_generate_queries_dedups_a_query_row_matching_a_schema_shape :: proc(t: ^testing.T) {
    columns_by_table := make(map[string][]Column)
    defer delete(columns_by_table)
    columns_by_table["widgets"] = []Column{{name = "id", type = "BLOB", not_null = true}}
    sources := map[string]string{}
    shapes := []Shape{{table = "widgets", name = "Widget_Row"}}

    // `Get_Widget`'s row is field-for-field identical to `Widget_Row` — same
    // name, type, and required-ness in the same order — so it should reuse the
    // schema shape's declaration rather than mint an identical `Get_Widget_Row`.
    resolved := []Resolved_Query {
        {
            def = Query_Def{name = "Get_Widget", cardinality = .One},
            params = []Resolved_Field{{name = "id", odin_type = "wire.Widget_Id", required = true}},
            row = []Resolved_Field{{name = "id", odin_type = "[]byte", required = true}},
        },
    }

    d: gen.Diags
    defer gen.diags_destroy(&d)

    data, ok := generate_queries(shapes, columns_by_table, sources, resolved, &d)
    defer delete(data)
    testing.expect(t, ok)

    text := string(data)
    testing.expect(t, strings.contains(text, "Widget_Row :: struct {"), "the schema shape's struct is emitted")
    testing.expect(
        t,
        !strings.contains(text, "Get_Widget_Row :: struct {"),
        "a query row identical to an existing struct does not get its own duplicate declaration",
    )
    testing.expect(
        t,
        strings.contains(
            text,
            "get_widget :: proc(q: ^Queries, params_in: Get_Widget_Params, allocator := context.allocator) -> (Widget_Row, sqlite.Error) {",
        ),
        "the wrapper's row type is the deduped, canonical name",
    )
    testing.expect(
        t,
        strings.contains(text, "get_widget: sqlite.Reader(Get_Widget_Params, Widget_Row),"),
        "the registry's row type is the deduped, canonical name",
    )
}

@(test)
test_generate_queries_emits_an_empty_params_struct_for_a_zero_param_query :: proc(t: ^testing.T) {
    columns_by_table := map[string][]Column{}
    sources := map[string]string{}
    resolved := []Resolved_Query{{def = Query_Def{name = "Get_Many", cardinality = .Many}}}

    d: gen.Diags
    defer gen.diags_destroy(&d)

    data, ok := generate_queries([]Shape{}, columns_by_table, sources, resolved, &d)
    defer delete(data)
    testing.expect(t, ok)

    text := string(data)
    testing.expect(
        t,
        strings.contains(text, "Get_Many_Params :: struct {\n}"),
        "a query with zero params still gets an (empty) Params struct — the registry references it unconditionally",
    )
}
