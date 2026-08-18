package wire
import "libs:json"

import "core:mem"
import "core:testing"

// A buffer the emitter cannot grow truncates the JSON. The write helpers compare what
// the builder took against what they handed it, so the shortfall is latched rather
// than shipped as a valid-looking prefix.
@(test)
test_emitter_latches_a_truncated_write :: proc(t: ^testing.T) {
    long: [512]byte
    for &c in long {
        c = 'x'
    }

    e: json.Emitter
    json.emitter_init(&e, context.allocator)
    defer json.emitter_destroy(&e)

    json.object_begin(&e)
    json.field_string(&e, "text", string(long[:]))
    json.object_end(&e)

    testing.expect(t, !e.failed, "a buffer that grows emits the whole value")
    testing.expect_value(t, len(json.to_string(&e)), len(long) + len(`{"text":""}`))

    backing: [64]byte
    arena: mem.Arena
    mem.arena_init(&arena, backing[:])

    capped: json.Emitter
    json.emitter_init(&capped, mem.arena_allocator(&arena))
    defer json.emitter_destroy(&capped)

    testing.expect(t, !capped.failed, "a fresh emitter is healthy")

    json.object_begin(&capped)
    json.field_string(&capped, "text", string(long[:]))
    json.object_end(&capped)

    testing.expect(t, capped.failed, "a buffer that cannot grow latches the failure")
    testing.expect(t, len(json.to_string(&capped)) <= len(backing), "the latched text is the truncated prefix")
}

// A payload emitted once and spliced into its envelope is byte-identical to the
// envelope built from the typed value: the durable path logs the one and sends the other.
@(test)
test_notification_raw_params_match_a_direct_emit :: proc(t: ^testing.T) {
    id := Session_Id([16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'})
    data := Broadcast_Data(Session_Deltas_Shed_Data{session_id = id, count = 3})

    params: json.Emitter
    json.emitter_init(&params, context.allocator)
    defer json.emitter_destroy(&params)
    broadcast_data_emit(&params, data)

    spliced: json.Emitter
    json.emitter_init(&spliced, context.allocator)
    defer json.emitter_destroy(&spliced)
    notification_emit_raw(&spliced, .Session_Deltas_Shed, json.to_string(&params))

    direct: json.Emitter
    json.emitter_init(&direct, context.allocator)
    defer json.emitter_destroy(&direct)
    notification_emit(&direct, notification_build(.Session_Deltas_Shed, data))

    testing.expect_value(t, json.to_string(&spliced), json.to_string(&direct))
    testing.expect(t, !spliced.failed, "the splice is healthy")
}
