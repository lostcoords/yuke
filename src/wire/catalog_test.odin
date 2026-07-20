package wire

import "core:strings"
import "core:testing"

@(test)
test_catalog_health_parses_null_load_error :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"skipped":[],"load_error":null}`
    v := decoder_init(input, context.temp_allocator)

    health, derr := catalog_health_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, len(health.skipped), 0)
    _, has_error := health.load_error.?
    testing.expect(t, !has_error, "load_error should be the null form")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    catalog_health_emit(&e, health)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_skip_reason_missing_credential_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"missing_credential","env":"ANTHROPIC_API_KEY"}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    reason, derr := skip_reason_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    mc, ok := reason.(Skip_Reason_Missing_Credential)
    testing.expect(t, ok, "should be a missing_credential")
    testing.expect_value(t, mc.env, "ANTHROPIC_API_KEY")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    skip_reason_emit(&e, reason)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_skip_reason_invalid_config_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"invalid_config","message":"bad provider config"}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    reason, derr := skip_reason_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    ic, ok := reason.(Skip_Reason_Invalid_Config)
    testing.expect(t, ok, "should be an invalid_config")
    testing.expect_value(t, ic.message, "bad provider config")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    skip_reason_emit(&e, reason)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_skip_reason_enforces_nested_bounds :: proc(t: ^testing.T) {
    missing := Skip_Reason(Skip_Reason_Missing_Credential{env = strings.repeat("x", 257, context.temp_allocator)})
    defer free_all(context.temp_allocator)
    testing.expect(t, skip_reason_validate(missing) == .Overflow, "oversized env must overflow")

    invalid := Skip_Reason(
        Skip_Reason_Invalid_Config {
            message = strings.repeat("x", LIMITS.max_error_message_bytes + 1, context.temp_allocator),
        },
    )
    testing.expect(t, skip_reason_validate(invalid) == .Overflow, "oversized message must overflow")
}

@(test)
test_catalog_list_result_unchanged_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"unchanged","catalog_rev":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"}`
    v := decoder_init(input, context.temp_allocator)

    result, derr := catalog_list_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    uc, ok := result.(Catalog_List_Result_Unchanged)
    testing.expect(t, ok, "should be the unchanged arm")
    rev := ([64]u8)(uc.catalog_rev)
    testing.expect_value(t, string(rev[:]), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    testing.expect(t, catalog_list_result_validate(result) == .None, "should validate")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    catalog_list_result_emit(&e, result)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_catalog_list_result_full_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"full","catalog_rev":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824","models":[{"id":"claude","provider":"anthropic","name":"Claude","context_window":200000,"max_output_tokens":8192,"reasoning_levels":["low","high"],"default_reasoning":"low","supports_vision":true,"supports_tools":true,"cost":{"input":3,"output":15,"cache_read":0.3,"cache_write":3.75}}],"health":{"skipped":[],"load_error":null}}`
    v := decoder_init(input, context.temp_allocator)

    result, derr := catalog_list_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    full, ok := result.(Catalog_List_Result_Full)
    testing.expect(t, ok, "should be the full arm")
    testing.expect_value(t, len(full.models), 1)
    testing.expect_value(t, full.models[0].id, "claude")
    testing.expect_value(t, len(full.models[0].reasoning_levels), 2)
    testing.expect_value(t, full.models[0].cost.input, 3.0)
    testing.expect_value(t, full.models[0].cost.cache_write, 3.75)
    testing.expect(t, catalog_list_result_validate(result) == .None, "should validate")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    catalog_list_result_emit(&e, result)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_catalog_list_result_unchanged_rejects_sibling :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"unchanged","catalog_rev":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824","models":[]}`
    v := decoder_init(input, context.temp_allocator)

    _, derr := catalog_list_result_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "sibling field must be rejected")
}
