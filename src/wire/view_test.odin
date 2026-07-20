package wire

import "core:strings"
import "core:testing"

@(test)
test_view_text_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"text","text":"hello","language":"zig"}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    view, derr := view_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    txt, ok := view.(View_Text)
    testing.expect(t, ok, "should be a text view")
    testing.expect_value(t, txt.text, "hello")
    lang, has := txt.language.?
    testing.expect(t, has, "language present")
    testing.expect_value(t, lang, "zig")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    view_emit(&e, view)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_view_markdown_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"markdown","text":"# Hi"}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    view, derr := view_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, ok := view.(View_Markdown)
    testing.expect(t, ok, "should be a markdown view")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    view_emit(&e, view)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_view_diff_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"diff","files":[{"path":"a.txt","hunks":[{"old_start":1,"old_lines":2,"new_start":1,"new_lines":3,"lines":["-a","+b","+c"]}]}]}`
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    v := decoder_init(input)

    view, derr := view_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    diff, ok := view.(View_Diff)
    testing.expect(t, ok, "should be a diff view")
    testing.expect_value(t, len(diff.files), 1)
    testing.expect_value(t, diff.files[0].path, "a.txt")
    testing.expect_value(t, len(diff.files[0].hunks), 1)
    testing.expect_value(t, diff.files[0].hunks[0].new_lines, u64(3))
    testing.expect_value(t, len(diff.files[0].hunks[0].lines), 3)

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    view_emit(&e, view)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_view_form_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"form","fields":[{"name":"email","label":"Email"},{"name":"tz","label":"Time zone","value":"UTC"}]}`
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    v := decoder_init(input)

    view, derr := view_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    form, ok := view.(View_Form)
    testing.expect(t, ok, "should be a form view")
    testing.expect_value(t, len(form.fields), 2)
    testing.expect_value(t, form.fields[0].name, "email")
    _, has0 := form.fields[0].value.?
    testing.expect(t, !has0, "first field has no value")
    val1, has1 := form.fields[1].value.?
    testing.expect(t, has1, "second field has a value")
    testing.expect_value(t, val1, "UTC")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    view_emit(&e, view)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_view_image_roundtrip :: proc(t: ^testing.T) {
    input := `{"type":"image","source":{"type":"url","url":"http://x/y.png"},"alt":"pic"}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    view, derr := view_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    img, ok := view.(View_Image)
    testing.expect(t, ok, "should be an image view")
    url, is_url := img.source.(Media_Url)
    testing.expect(t, is_url, "source should be a url")
    testing.expect_value(t, url.url, "http://x/y.png")
    alt, has := img.alt.?
    testing.expect(t, has, "alt present")
    testing.expect_value(t, alt, "pic")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    view_emit(&e, view)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_view_sibling_field_rejected :: proc(t: ^testing.T) {
    // `files` belongs to the diff arm; its presence under `text` is a mismatch.
    v := decoder_init(`{"type":"text","text":"x","files":[]}`, context.temp_allocator)
    defer free_all(context.temp_allocator)
    _, derr := view_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "sibling key must be rejected")
}

@(test)
test_view_rejects_aggregate_above_cap :: proc(t: ^testing.T) {
    text := strings.repeat("x", LIMITS.max_view_bytes + 1, context.temp_allocator)
    defer free_all(context.temp_allocator)
    view := View(View_Markdown{text = text})
    testing.expect(t, view_validate(view) == .Overflow, "aggregate above cap must overflow")
}
