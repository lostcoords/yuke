package wire
import "libs:json"

import "core:strings"
import "core:testing"

@(test)
test_run_outcome_turn_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"turn","finish":"stop","rounds":3}`
    v := json.decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    outcome, derr := run_outcome_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    turn, ok := outcome.(Run_Outcome_Turn)
    testing.expect(t, ok, "should be a turn")
    testing.expect_value(t, turn.finish, Stop_Reason.Stop)
    testing.expect_value(t, turn.rounds, u64(3))

    e: json.Emitter
    json.emitter_init(&e)
    defer json.emitter_destroy(&e)
    run_outcome_emit(&e, outcome)
    testing.expect_value(t, json.to_string(&e), input)
}

@(test)
test_run_outcome_compacted_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"compacted","message_id":42}`
    v := json.decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    outcome, derr := run_outcome_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    c, ok := outcome.(Run_Outcome_Compacted)
    testing.expect(t, ok, "should be compacted")
    testing.expect_value(t, u64(c.message_id), u64(42))

    e: json.Emitter
    json.emitter_init(&e)
    defer json.emitter_destroy(&e)
    run_outcome_emit(&e, outcome)
    testing.expect_value(t, json.to_string(&e), input)
}

@(test)
test_run_outcome_skipped_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"skipped","reason":"too_few_messages"}`
    v := json.decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    outcome, derr := run_outcome_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    s, ok := outcome.(Run_Outcome_Skipped)
    testing.expect(t, ok, "should be skipped")
    testing.expect_value(t, s.reason, Compact_Skip_Reason.Too_Few_Messages)

    e: json.Emitter
    json.emitter_init(&e)
    defer json.emitter_destroy(&e)
    run_outcome_emit(&e, outcome)
    testing.expect_value(t, json.to_string(&e), input)
}

@(test)
test_run_outcome_canceled_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"canceled"}`
    v := json.decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    outcome, derr := run_outcome_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, ok := outcome.(Run_Outcome_Canceled)
    testing.expect(t, ok, "should be canceled")

    e: json.Emitter
    json.emitter_init(&e)
    defer json.emitter_destroy(&e)
    run_outcome_emit(&e, outcome)
    testing.expect_value(t, json.to_string(&e), input)
}

@(test)
test_run_outcome_failed_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"failed","code":"runtime","message":"boom"}`
    v := json.decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    outcome, derr := run_outcome_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    f, ok := outcome.(Run_Outcome_Failed)
    testing.expect(t, ok, "should be failed")
    testing.expect_value(t, f.code, Run_Error_Code.Runtime)
    testing.expect_value(t, f.message, "boom")
    testing.expect(t, run_outcome_validate(outcome) == .None, "short message is within bound")

    e: json.Emitter
    json.emitter_init(&e)
    defer json.emitter_destroy(&e)
    run_outcome_emit(&e, outcome)
    testing.expect_value(t, json.to_string(&e), input)
}

@(test)
test_run_outcome_sibling_rejected :: proc(t: ^testing.T) {
    // `message_id` belongs to the compacted arm; its presence under `turn` is a mismatch.
    v := json.decoder_init(`{"type":"turn","finish":"stop","rounds":1,"message_id":9}`, context.temp_allocator)
    defer free_all(context.temp_allocator)
    _, derr := run_outcome_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "sibling key must be rejected")
}

@(test)
test_run_outcome_failed_rejects_oversized_message :: proc(t: ^testing.T) {
    long := strings.repeat("x", LIMITS.max_error_message_bytes + 1, context.temp_allocator)
    defer free_all(context.temp_allocator)
    outcome := Run_Outcome(Run_Outcome_Failed{code = .Internal, message = long})
    testing.expect(t, run_outcome_validate(outcome) == .Overflow, "oversized message must overflow")
}

@(test)
test_run_canceled_timing_null_start_roundtrip :: proc(t: ^testing.T) {
    // A queued run canceled before starting has a null started_at_ms, always emitted.
    input := `{"started_at_ms":null,"ended_at_ms":100}`
    v := json.decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    timing, derr := run_canceled_timing_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, has := timing.started_at_ms.?
    testing.expect(t, !has, "started_at_ms should be absent")
    testing.expect_value(t, timing.ended_at_ms, u64(100))

    e: json.Emitter
    json.emitter_init(&e)
    defer json.emitter_destroy(&e)
    run_canceled_timing_emit(&e, timing)
    testing.expect_value(t, json.to_string(&e), input)
}
