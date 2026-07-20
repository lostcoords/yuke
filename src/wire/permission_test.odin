package wire

import "core:testing"

@(test)
test_permission_decision_user_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"user","option_id":"opt-1","kind":"allow_once","label":"Allow once","resolved_at_ms":1700000000000,"decided_by":{"name":"yuke-tui","version":"1.0.0"}}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    dec, derr := permission_decision_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    user, ok := dec.(Permission_Decision_User)
    testing.expect(t, ok, "should be a user decision")
    testing.expect_value(t, user.option_id, "opt-1")
    testing.expect_value(t, user.kind, Permission_Option_Kind.Allow_Once)
    testing.expect_value(t, user.decided_by.name, "yuke-tui")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    permission_decision_emit(&e, dec)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_permission_decision_rule_decode :: proc(t: ^testing.T) {
    // Discriminator normalized to `type` (Zig used `by`); values are unchanged.
    input := `{"type":"rule","rule_id":"0123456789abcdef","label":"allow git status","resolved_at_ms":1700000000000}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    dec, derr := permission_decision_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    rule, ok := dec.(Permission_Decision_Rule)
    testing.expect(t, ok, "should be a rule decision")
    rid := ([16]u8)(rule.rule_id)
    testing.expect_value(t, string(rid[:]), "0123456789abcdef")
    testing.expect_value(t, rule.label, "allow git status")

    testing.expect(t, permission_decision_validate(dec) == .None, "rule decision should validate")
}

@(test)
test_permission_decision_rejects_sibling_field :: proc(t: ^testing.T) {
    // A user-arm field under the `rule` tag is a payload mismatch.
    input := `{"type":"rule","rule_id":"0123456789abcdef","label":"x","resolved_at_ms":1,"option_id":"opt-1"}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    _, derr := permission_decision_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "sibling field must be rejected")
}

@(test)
test_permission_rule_roundtrip :: proc(t: ^testing.T) {
    input := `{"id":"0123456789abcdef","tool":"bash","label":"allow bash","created_at_ms":1700000000000,"created_by":{"name":"yuke-tui","version":"1.0.0"}}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    rule, derr := permission_rule_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, rule.tool, "bash")
    _, has_session := rule.session_id.?
    testing.expect(t, !has_session, "session_id should be absent")
    testing.expect(t, permission_rule_validate(rule) == .None, "rule should validate")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    permission_rule_emit(&e, rule)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_permission_decide_params_roundtrip :: proc(t: ^testing.T) {
    input := `{"session_id":"0123456789abcdef","message_id":42,"part_id":3,"option_id":"opt-1"}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    params, derr := permission_decide_params_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, u64(params.message_id), u64(42))
    testing.expect_value(t, u64(params.part_id), u64(3))
    testing.expect(t, permission_decide_params_validate(params) == .None, "params should validate")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    permission_decide_params_emit(&e, params)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_permission_rules_result_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    input := `{"rules":[{"id":"0123456789abcdef","tool":"bash","label":"allow bash","created_at_ms":1700000000000,"created_by":{"name":"yuke-tui","version":"1.0.0"}}]}`
    v := decoder_init(input, context.temp_allocator)

    result, derr := permission_rules_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, len(result.rules), 1)
    testing.expect(t, permission_rules_result_validate(result) == .None, "result should validate")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    permission_rules_result_emit(&e, result)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_permission_state_requires_one_lifecycle :: proc(t: ^testing.T) {
    // Neither options nor decision: mismatched.
    s0 := Permission_State {
        requested_at_ms = 1,
    }
    testing.expect(t, permission_state_validate(s0) == .Mismatched_Payload, "neither present must mismatch")

    // Both options and decision: mismatched.
    rid: [16]u8
    copy(rid[:], "0123456789abcdef")
    s1 := Permission_State {
        requested_at_ms = 1,
        options         = []Permission_Option{},
        decision        = Permission_Decision(
            Permission_Decision_Rule{rule_id = Rule_Id(rid), label = "allow", resolved_at_ms = 2},
        ),
    }
    testing.expect(t, permission_state_validate(s1) == .Mismatched_Payload, "both present must mismatch")

    // Only options: ok.
    s2 := Permission_State {
        requested_at_ms = 1,
        options         = []Permission_Option{},
    }
    testing.expect(t, permission_state_validate(s2) == .None, "only options must validate")
}

// Regression: cloning a decision-less permission state must keep `decision` absent.
// Assigning a bare (nil) `Permission_Decision` union to the `Maybe` field previously
// wrapped it as present, corrupting the options/decision invariant on cloned values.
@(test)
test_permission_state_clone_preserves_absent_decision :: proc(t: ^testing.T) {
    src := Permission_State {
        requested_at_ms = 3,
        options         = []Permission_Option{{id = "a", kind = .Allow_Once, label = "A"}},
    }

    cloned := permission_state_clone(src, context.temp_allocator)
    _, has_decision := cloned.decision.?
    testing.expect(t, !has_decision, "cloned decision must stay absent")

    _, has_options := cloned.options.?
    testing.expect(t, has_options, "cloned options must stay present")
}
