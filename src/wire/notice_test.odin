package wire

import "core:testing"

@(test)
test_notice_parses_global_diagnostic :: proc(t: ^testing.T) {
    input := `{"level":"warn","source":"provider","message":"rate limited"}`
    d := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    n, derr := notice_from_reader(&d)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, n.level, Notice_Level.Warn)
    testing.expect_value(t, n.source, "provider")
    testing.expect(t, notice_validate(n) == .None, "notice should validate")
}

@(test)
test_notice_roundtrip :: proc(t: ^testing.T) {
    input := `{"level":"error","source":"provider","message":"rate limited"}`
    d := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    n, derr := notice_from_reader(&d)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, n.level, Notice_Level.Error)

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    notice_emit(&e, n)
    testing.expect_value(t, to_string(&e), input)
}
