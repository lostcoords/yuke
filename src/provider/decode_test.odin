package provider

import "core:encoding/json"
import "core:mem"
import "core:testing"
import ts "libs:testsupport"

@(test)
test_decode_json_object_is_single_strict_value :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    value, object, err := decode_json_object(`{"type":"event","unknown":{"x":1}}`, context.temp_allocator)
    testing.expect_value(t, err, Transport_Error.None)
    testing.expect_value(t, len(object), 2)
    json.destroy_value(value, context.temp_allocator)

    _, _, err = decode_json_object(`[]`, context.temp_allocator)
    testing.expect_value(t, err, Transport_Error.Parse_Error)

    _, _, err = decode_json_object(`{"x":1} {"y":2}`, context.temp_allocator)
    testing.expect_value(t, err, Transport_Error.Parse_Error)

    _, _, err = decode_json_object(`{"x":1,"x":2}`, context.temp_allocator)
    testing.expect_value(t, err, Transport_Error.Parse_Error)

    _, _, err = decode_json_object(`{"x":`, context.temp_allocator)
    testing.expect_value(t, err, Transport_Error.Parse_Error)
}

@(test)
test_decode_json_object_surfaces_allocation_failure :: proc(t: ^testing.T) {
    failing: ts.Failing_Allocator
    ts.failing_allocator_init(&failing, context.allocator, 0)

    _, _, err := decode_json_object(`{"type":"event"}`, ts.failing_allocator(&failing))
    testing.expect_value(t, err, Transport_Error.Resource_Exhausted)
}

// Malformed JSON can leave the Odin parser holding an allocation the returned
// value never references (a cloned object key parsed before the value failed).
// A bulk-reclaimable scratch owner is what keeps the decode boundary leak-free:
// parsing into an arena and destroying it must leave nothing under the checked
// heap allocator, even when the failure lands after a key, mid nested array, or
// after a duplicate key.
@(test)
test_decode_json_object_malformed_reclaims_in_arena :: proc(t: ^testing.T) {
    malformed := [?]string{`{"choices":[}`, `{"a":`, `{"a":[1,2,`, `{"x":1,"x":`}

    for data in malformed {
        arena: mem.Dynamic_Arena
        mem.dynamic_arena_init(&arena, context.allocator, context.allocator)

        _, _, err := decode_json_object(data, mem.dynamic_arena_allocator(&arena))
        testing.expectf(t, err == .Parse_Error, "%s: want Parse_Error, got %v", data, err)

        mem.dynamic_arena_destroy(&arena)
    }
}

@(test)
test_decode_optional_fields :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    value, object, err := decode_json_object(
        `{"object":{"x":1},"string":"text","integer":7,"null":null,"fraction":1.5,"negative":-1}`,
        context.temp_allocator,
    )
    testing.expect_value(t, err, Transport_Error.None)
    defer json.destroy_value(value, context.temp_allocator)

    child, present, ferr := decode_optional_object(object, "object")
    testing.expect_value(t, ferr, Transport_Error.None)
    testing.expect(t, present, "object field must be present")
    testing.expect_value(t, decode_usage_u64(child, "x"), u64(1))

    text, text_present, text_err := decode_optional_string(object, "string")
    testing.expect_value(t, text_err, Transport_Error.None)
    testing.expect(t, text_present, "string field must be present")
    testing.expect_value(t, text, "text")

    integer, integer_present, integer_err := decode_optional_u64(object, "integer")
    testing.expect_value(t, integer_err, Transport_Error.None)
    testing.expect(t, integer_present, "integer field must be present")
    testing.expect_value(t, integer, u64(7))

    _, null_present, null_err := decode_optional_string(object, "null")
    testing.expect_value(t, null_err, Transport_Error.None)
    testing.expect(t, !null_present, "null field must be absent")

    _, missing_present, missing_err := decode_optional_string(object, "missing")
    testing.expect_value(t, missing_err, Transport_Error.None)
    testing.expect(t, !missing_present, "missing field must be absent")

    _, _, fraction_err := decode_optional_u64(object, "fraction")
    testing.expect_value(t, fraction_err, Transport_Error.Parse_Error)

    _, _, negative_err := decode_optional_u64(object, "negative")
    testing.expect_value(t, negative_err, Transport_Error.Parse_Error)

    _, _, object_err := decode_optional_object(object, "string")
    testing.expect_value(t, object_err, Transport_Error.Parse_Error)
}

@(test)
test_decode_usage_u64_defaults_invalid_metadata_to_zero :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    value, object, err := decode_json_object(
        `{"whole":5,"float_whole":3.0,"fraction":2.5,"negative":-1,"text":"7","too_large":9007199254740992}`,
        context.temp_allocator,
    )
    testing.expect_value(t, err, Transport_Error.None)
    defer json.destroy_value(value, context.temp_allocator)

    testing.expect_value(t, decode_usage_u64(object, "whole"), u64(5))
    testing.expect_value(t, decode_usage_u64(object, "float_whole"), u64(3))
    testing.expect_value(t, decode_usage_u64(object, "fraction"), u64(0))
    testing.expect_value(t, decode_usage_u64(object, "negative"), u64(0))
    testing.expect_value(t, decode_usage_u64(object, "text"), u64(0))
    testing.expect_value(t, decode_usage_u64(object, "too_large"), u64(0))
    testing.expect_value(t, decode_usage_u64(object, "missing"), u64(0))
}
