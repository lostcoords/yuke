package wire

import "core:testing"

@(test)
test_cron_schedule_every_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"every","interval_ms":300000}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    sched, derr := cron_schedule_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    every, ok := sched.(Cron_Schedule_Every)
    testing.expect(t, ok, "should be an every schedule")
    testing.expect_value(t, every.interval_ms, u64(300000))

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    cron_schedule_emit(&e, sched)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_cron_schedule_cron_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"cron","expr":"0 9 * * 1-5","utc_offset_minutes":-480}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    sched, derr := cron_schedule_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    cr, ok := sched.(Cron_Schedule_Cron)
    testing.expect(t, ok, "should be a cron schedule")
    testing.expect_value(t, cr.expr, "0 9 * * 1-5")
    testing.expect_value(t, cr.utc_offset_minutes, i64(-480))

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    cron_schedule_emit(&e, sched)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_cron_schedule_at_after_roundtrip :: proc(t: ^testing.T) {
    {
        input := `{"type":"at","at_ms":1700000000000}`
        v := decoder_init(input, context.temp_allocator)
        defer free_all(context.temp_allocator)
        sched, derr := cron_schedule_from_reader(&v)
        testing.expect(t, derr == .None, "decode should succeed")
        at, ok := sched.(Cron_Schedule_At)
        testing.expect(t, ok, "should be an at schedule")
        testing.expect_value(t, at.at_ms, u64(1700000000000))
        e: Emitter
        emitter_init(&e)
        defer emitter_destroy(&e)
        cron_schedule_emit(&e, sched)
        testing.expect_value(t, to_string(&e), input)
    }
    {
        input := `{"type":"after","delay_ms":60000}`
        v := decoder_init(input, context.temp_allocator)
        defer free_all(context.temp_allocator)
        sched, derr := cron_schedule_from_reader(&v)
        testing.expect(t, derr == .None, "decode should succeed")
        after, ok := sched.(Cron_Schedule_After)
        testing.expect(t, ok, "should be an after schedule")
        testing.expect_value(t, after.delay_ms, u64(60000))
        e: Emitter
        emitter_init(&e)
        defer emitter_destroy(&e)
        cron_schedule_emit(&e, sched)
        testing.expect_value(t, to_string(&e), input)
    }
}

@(test)
test_cron_schedule_rejects_sibling_field :: proc(t: ^testing.T) {
    v := decoder_init(`{"type":"every","interval_ms":1,"at_ms":2}`, context.temp_allocator)
    defer free_all(context.temp_allocator)
    _, derr := cron_schedule_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "sibling key must be rejected")
}

@(test)
test_cron_job_roundtrip_and_validate :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"id":"0123456789abcdef","spec":{"schedule":{"type":"every","interval_ms":60000},"session":{"workspace_path":"/h"},"retain":"always","input":{"type":"content","content":[]},"on_missed":"skip","overlap":"skip","delete_after_run":false},"enabled":false,"created_at_ms":1000,"next_run_ms":2000,"last_run_ms":1500,"last_session_id":"fedcba9876543210","last_outcome":"completed","run_count":3,"dispatch_failures":1}`

    v := decoder_init(input, context.temp_allocator)

    job, derr := cron_job_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")

    outcome, ok := job.last_outcome.?
    testing.expect(t, ok, "last_outcome should be present")
    testing.expect_value(t, outcome, Cron_Run_Outcome.Completed)
    testing.expect_value(t, job.run_count, u64(3))
    testing.expect_value(t, job.dispatch_failures, u64(1))
    _, has_next := job.next_run_ms.?
    testing.expect(t, has_next, "next_run_ms should be present")

    testing.expect(t, cron_job_validate(job) == .None, "job should validate")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    cron_job_emit(&e, job)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_cron_job_accepts_all_null_required_null :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"id":"0123456789abcdef","spec":{"schedule":{"type":"every","interval_ms":60000},"session":{"workspace_path":"/h"},"retain":"always","input":{"type":"content","content":[]},"on_missed":"skip","overlap":"skip","delete_after_run":false},"enabled":true,"created_at_ms":1,"next_run_ms":null,"last_run_ms":null,"last_session_id":null,"last_outcome":null,"run_count":0,"dispatch_failures":0}`

    v := decoder_init(input, context.temp_allocator)

    job, derr := cron_job_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")

    _, has_next := job.next_run_ms.?
    testing.expect(t, !has_next, "next_run_ms should be null")
    _, has_outcome := job.last_outcome.?
    testing.expect(t, !has_outcome, "last_outcome should be null")
    testing.expect(t, cron_job_validate(job) == .None, "job should validate")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    cron_job_emit(&e, job)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_cron_create_params_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"spec":{"schedule":{"type":"every","interval_ms":60000},"session":{"workspace_path":"/h","model":"openai/gpt"},"retain":"always","input":{"type":"content","content":[]},"on_missed":"skip","overlap":"skip","delete_after_run":false}}`

    v := decoder_init(input, context.temp_allocator)

    params, derr := cron_create_params_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, params.spec.retain, Cron_Retain.Always)
    testing.expect(t, cron_create_params_validate(params) == .None, "params should validate")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    cron_create_params_emit(&e, params)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_cron_patch_roundtrip :: proc(t: ^testing.T) {
    input := `{"session":{"workspace_path":"/h","model":"openai/gpt"},"enabled":true}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    patch, derr := cron_patch_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    sess, ok := patch.session.?
    testing.expect(t, ok, "session should be present")
    model, has_model := sess.model.?
    testing.expect(t, has_model, "model override should be present")
    testing.expect_value(t, model, "openai/gpt")
    enabled, has_enabled := patch.enabled.?
    testing.expect(t, has_enabled, "enabled should be present")
    testing.expect(t, enabled, "enabled should be true")
    testing.expect(t, cron_patch_validate(patch) == .None, "patch should validate")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    cron_patch_emit(&e, patch)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_cron_list_result_roundtrip_pagination :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    // A non-final page carries an opaque continuation cursor.
    {
        input := `{"revision":5,"jobs":[],"next_cursor":"opaque"}`
        v := decoder_init(input, context.temp_allocator)
        result, derr := cron_list_result_from_reader(&v)
        testing.expect(t, derr == .None, "decode should succeed")
        testing.expect_value(t, u64(result.revision), u64(5))
        cursor, ok := result.next_cursor.?
        testing.expect(t, ok, "next_cursor should be present")
        testing.expect_value(t, cursor, "opaque")
        testing.expect(t, cron_list_result_validate(result) == .None, "result should validate")
        e: Emitter
        emitter_init(&e)
        defer emitter_destroy(&e)
        cron_list_result_emit(&e, result)
        testing.expect_value(t, to_string(&e), input)
    }
    // The final page marks `next_cursor` explicitly null.
    {
        input := `{"revision":0,"jobs":[],"next_cursor":null}`
        v := decoder_init(input, context.temp_allocator)
        result, derr := cron_list_result_from_reader(&v)
        testing.expect(t, derr == .None, "decode should succeed")
        _, ok := result.next_cursor.?
        testing.expect(t, !ok, "next_cursor should be null")
        testing.expect(t, cron_list_result_validate(result) == .None, "result should validate")
        e: Emitter
        emitter_init(&e)
        defer emitter_destroy(&e)
        cron_list_result_emit(&e, result)
        testing.expect_value(t, to_string(&e), input)
    }
}

@(test)
test_cron_list_params_roundtrip :: proc(t: ^testing.T) {
    input := `{"limit":10,"cursor":"c"}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    params, derr := cron_list_params_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    limit, ok := params.limit.?
    testing.expect(t, ok, "limit should be present")
    testing.expect_value(t, limit, u64(10))
    testing.expect(t, cron_list_params_validate(params) == .None, "params should validate")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    cron_list_params_emit(&e, params)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_cron_list_params_rejects_zero_limit :: proc(t: ^testing.T) {
    params := Cron_List_Params {
        limit = u64(0),
    }
    testing.expect(t, cron_list_params_validate(params) == .Out_Of_Range, "zero limit must be out of range")
}

@(test)
test_cron_run_now_result_roundtrip :: proc(t: ^testing.T) {
    input := `{"session_id":"0123456789abcdef","run_id":7}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    result, derr := cron_run_now_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, u64(result.run_id), u64(7))
    testing.expect(t, cron_run_now_result_validate(result) == .None, "result should validate")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    cron_run_now_result_emit(&e, result)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_cron_run_now_params_rejects_bad_id :: proc(t: ^testing.T) {
    bad: [16]u8
    s := "g123456789abcdef"
    for i in 0 ..< 16 {
        bad[i] = s[i]
    }

    params := Cron_Run_Now_Params {
        job_id = Job_Id(bad),
    }
    testing.expect(t, cron_run_now_params_validate(params) == .Invalid_Hex, "non-hex id must be rejected")
}

@(test)
test_cron_job_rejects_missing_next_run_ms :: proc(t: ^testing.T) {
    // A required-but-nullable field must be present on the wire (null is allowed,
    // absent is not) — mirrors the always-present emit side.
    input := `{"id":"0123456789abcdef","spec":{"schedule":{"type":"every","interval_ms":60000},"session":{"workspace_path":"/h"},"retain":"always","input":{"type":"content","content":[]},"on_missed":"skip","overlap":"skip","delete_after_run":false},"enabled":true,"created_at_ms":1,"last_run_ms":null,"last_session_id":null,"last_outcome":null,"run_count":0,"dispatch_failures":0}`
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    v := decoder_init(input, context.temp_allocator)
    _, derr := cron_job_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "missing next_run_ms must be rejected")
}

@(test)
test_cron_job_rejects_missing_last_session_id :: proc(t: ^testing.T) {
    input := `{"id":"0123456789abcdef","spec":{"schedule":{"type":"every","interval_ms":60000},"session":{"workspace_path":"/h"},"retain":"always","input":{"type":"content","content":[]},"on_missed":"skip","overlap":"skip","delete_after_run":false},"enabled":true,"created_at_ms":1,"next_run_ms":null,"last_run_ms":null,"last_outcome":null,"run_count":0,"dispatch_failures":0}`
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    v := decoder_init(input, context.temp_allocator)
    _, derr := cron_job_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "missing last_session_id must be rejected")
}
