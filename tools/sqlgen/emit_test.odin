package sqlgen

import "core:strings"
import "core:testing"

import "tools:gen"

@(test)
test_scalar_type_maps_the_unambiguous_storage_classes :: proc(t: ^testing.T) {
    odin_type, ok := scalar_type("BLOB")
    testing.expect(t, ok)
    testing.expect_value(t, odin_type, "[]byte")

    odin_type, ok = scalar_type("TEXT")
    testing.expect(t, ok)
    testing.expect_value(t, odin_type, "string")

    odin_type, ok = scalar_type("REAL")
    testing.expect(t, ok)
    testing.expect_value(t, odin_type, "f64")

    _, ok = scalar_type("INTEGER")
    testing.expect(t, !ok, "INTEGER's Odin type isn't fixed by storage class; it must be annotated, not guessed")

    _, ok = scalar_type("NUMERIC")
    testing.expect(t, !ok, "an unmapped storage class is refused, not guessed at")
}

@(test)
test_base_type_for_requires_an_annotation_on_an_integer_column :: proc(t: ^testing.T) {
    shape := Shape {
        table = "t",
    }
    sources := map[string]string{}
    d: gen.Diags
    defer gen.diags_destroy(&d)

    _, ok := base_type_for(shape, Column{name = "n", type = "INTEGER", not_null = true}, sources, &d)
    testing.expect(t, !ok, "an unannotated INTEGER column cannot be silently typed u64")
    testing.expect(t, gen.diags_failed(&d), "the missing annotation is reported, not guessed at")
}

@(test)
test_base_type_for_never_wraps_maybe_itself :: proc(t: ^testing.T) {
    // Maybe-wrapping is `shape_fields`'s job; `base_type_for` only ever
    // resolves the unwrapped type.
    shape := Shape {
        table = "t",
    }
    sources := map[string]string{}
    d: gen.Diags
    defer gen.diags_destroy(&d)

    base, ok := base_type_for(shape, Column{name = "a", type = "TEXT", not_null = false}, sources, &d)
    testing.expect(t, ok)
    testing.expect_value(t, base, "string")
    testing.expect(t, !gen.diags_failed(&d), "a mapped storage class raises nothing")
}

@(test)
test_base_type_for_prefers_the_annotation_over_the_storage_class :: proc(t: ^testing.T) {
    shape := Shape {
        table = "sessions",
    }
    sources := make(map[string]string)
    defer delete(sources)
    sources["0001.sql"] = "CREATE TABLE sessions (\n    id BLOB PRIMARY KEY, -- wire.Session_Id\n);\n"
    d: gen.Diags
    defer gen.diags_destroy(&d)

    odin_type, ok := base_type_for(shape, Column{name = "id", type = "BLOB", not_null = true}, sources, &d)
    testing.expect(t, ok)
    testing.expect_value(t, odin_type, "wire.Session_Id")
}

@(test)
test_base_type_for_reports_an_unmapped_storage_class :: proc(t: ^testing.T) {
    shape := Shape {
        table = "t",
    }
    sources := map[string]string{}
    d: gen.Diags
    defer gen.diags_destroy(&d)

    _, ok := base_type_for(shape, Column{name = "a", type = "NUMERIC", not_null = true}, sources, &d)
    testing.expect(t, !ok, "an unmapped, unannotated column cannot be generated")
    testing.expect(t, gen.diags_failed(&d), "the failure is reported, not silent")
}

@(test)
test_generate_builds_one_struct_per_shape_excluding_configured_columns :: proc(t: ^testing.T) {
    columns_by_table := make(map[string][]Column)
    defer delete(columns_by_table)
    columns_by_table["widgets"] = []Column {
        {name = "id", type = "BLOB", not_null = true},
        {name = "internal_mark", type = "INTEGER", not_null = true},
        {name = "label", type = "TEXT", not_null = false},
    }
    sources := make(map[string]string)
    defer delete(sources)
    sources["0001.sql"] = "CREATE TABLE widgets (\n    id BLOB, -- wire.Widget_Id\n);\n"
    shapes := []Shape{{table = "widgets", name = "Widget_Params", exclude = {"internal_mark"}}}
    d: gen.Diags
    defer gen.diags_destroy(&d)

    data, ok := generate_queries(shapes, columns_by_table, sources, {}, &d)
    defer delete(data)
    testing.expect(t, ok)
    testing.expect(t, !gen.diags_failed(&d))

    text := string(data)
    testing.expect(t, strings.contains(text, "Widget_Params :: struct {"), "the shape's struct is emitted")
    testing.expect(t, strings.contains(text, "id: wire.Widget_Id,"), "the annotated column uses its wire type")
    testing.expect(t, strings.contains(text, "label: Maybe(string),"), "a nullable plain column is Maybe-wrapped")
    testing.expect(
        t,
        !strings.contains(text, "internal_mark"),
        "an excluded column never reaches the generated struct",
    )
}

@(test)
test_generate_reports_a_shape_excluding_an_unknown_column :: proc(t: ^testing.T) {
    columns_by_table := make(map[string][]Column)
    defer delete(columns_by_table)
    columns_by_table["widgets"] = []Column{{name = "id", type = "BLOB", not_null = true}}
    sources := map[string]string{}
    shapes := []Shape{{table = "widgets", name = "Widget_Params", exclude = {"typo_column"}}}
    d: gen.Diags
    defer gen.diags_destroy(&d)

    _, ok := generate_queries(shapes, columns_by_table, sources, {}, &d)
    testing.expect(t, !ok, "an exclude that names no real column cannot silently do nothing")
    testing.expect(t, gen.diags_failed(&d))
}

@(test)
test_generate_reports_a_shape_naming_an_unknown_table :: proc(t: ^testing.T) {
    columns_by_table := map[string][]Column{}
    sources := map[string]string{}
    shapes := []Shape{{table = "nope", name = "Nope_Params"}}
    d: gen.Diags
    defer gen.diags_destroy(&d)

    _, ok := generate_queries(shapes, columns_by_table, sources, {}, &d)
    testing.expect(t, !ok, "a shape whose table was never introspected cannot generate")
    testing.expect(t, gen.diags_failed(&d))
}
