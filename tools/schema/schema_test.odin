package schema

import "core:testing"

@(test)
test_presence_markers :: proc(t: ^testing.T) {
    presence, expr, ok := presence_marker_parse("@default PROTOCOL_VERSION")
    testing.expect(t, ok, "default marker should parse")
    testing.expect_value(t, presence, Presence.Defaulted)
    testing.expect_value(t, expr, "PROTOCOL_VERSION")

    presence, _, ok = presence_marker_parse("@required-nullable")
    testing.expect(t, ok, "required-nullable marker should parse")
    testing.expect_value(t, presence, Presence.Required_Nullable)

    _, _, ok = presence_marker_parse("mentions @optional in prose")
    testing.expect(t, !ok, "a marker embedded in prose must not parse")
}

@(test)
test_defaulted_field_is_not_required :: proc(t: ^testing.T) {
    testing.expect(t, !field_is_required(Field{presence = .Defaulted}), "decoder defaults permit omission")
    testing.expect(
        t,
        field_is_required(Field{presence = .Required_Nullable}),
        "nullable values still require a member",
    )
}

@(test)
test_signed_integer_schema_has_both_bounds :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    m := Model{}
    m.consts["MAX_WIRE_INTEGER"] = 9_007_199_254_740_991
    node := integer_schema(&m, "i64")
    _, has_minimum := node["minimum"]
    _, has_maximum := node["maximum"]
    testing.expect(t, has_minimum, "signed integers need a minimum")
    testing.expect(t, has_maximum, "all wire integers need a maximum")
}
