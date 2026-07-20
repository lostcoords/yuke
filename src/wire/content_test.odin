package wire

import "core:testing"

@(test)
test_content_part_text_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"text","text":"hello"}`
    d := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    part, derr := content_part_from_reader(&d)
    testing.expect(t, derr == .None, "decode should succeed")
    txt, ok := part.(Content_Text)
    testing.expect(t, ok, "should be a text part")
    testing.expect_value(t, txt.text, "hello")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    content_part_emit(&e, part)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_media_source_blob_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"blob","hash":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824","mime":"image/png","bytes":1024}`
    d := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    src, derr := media_source_from_reader(&d)
    testing.expect(t, derr == .None, "decode should succeed")
    blob, ok := src.(Media_Blob)
    testing.expect(t, ok, "should be a blob source")
    testing.expect_value(t, blob.bytes, u64(1024))
    testing.expect_value(t, blob.mime, "image/png")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    media_source_emit(&e, src)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_media_source_unknown_ignored_sibling_rejected :: proc(t: ^testing.T) {
    // An unknown key is ignored.
    {
        d := decoder_init(`{"type":"url","url":"http://x","bogus":1}`, context.temp_allocator)
        defer free_all(context.temp_allocator)
        src, derr := media_source_from_reader(&d)
        testing.expect(t, derr == .None, "unknown key must be ignored")
        _, ok := src.(Media_Url)
        testing.expect(t, ok, "should decode as url")
    }
    // A sibling variant's key is rejected.
    {
        d := decoder_init(`{"type":"url","url":"http://x","mime":"y"}`, context.temp_allocator)
        defer free_all(context.temp_allocator)
        _, derr := media_source_from_reader(&d)
        testing.expect(t, derr == .Mismatched_Payload, "sibling key must be rejected")
    }
}

@(test)
test_media_source_rejects_oversized_blob :: proc(t: ^testing.T) {
    hash: [64]u8
    for i in 0 ..< 64 {
        hash[i] = 'a'
    }

    src := Media_Blob {
        hash  = hash,
        mime  = "application/octet-stream",
        bytes = LIMITS.max_blob_bytes + 1,
    }
    testing.expect(t, media_source_validate(src) == .Overflow, "oversized blob must overflow")
}
