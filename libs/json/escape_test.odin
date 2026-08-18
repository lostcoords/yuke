package json

import "core:strings"
import "core:testing"

@(private)
escaped :: proc(s: string) -> string {
    b := strings.builder_make(context.temp_allocator)
    write_string(strings.to_writer(&b), s)
    return strings.to_string(b)
}

@(test)
test_ascii_is_verbatim :: proc(t: ^testing.T) {
    testing.expect_value(t, escaped("hello"), `"hello"`)
}

@(test)
test_quote_and_backslash_escape :: proc(t: ^testing.T) {
    testing.expect_value(t, escaped(`a"b\c`), `"a\"b\\c"`)
}

@(test)
test_c0_controls :: proc(t: ^testing.T) {
    testing.expect_value(t, escaped("\n\r\t\b\f"), `"\n\r\t\b\f"`)
    testing.expect_value(t, escaped("\x00\x01\x1f"), "\"\\u0000\\u0001\\u001f\"")
}

@(test)
test_del_is_not_escaped :: proc(t: ^testing.T) {
    // 0x7f isn't a C0 control, so it stays verbatim.
    testing.expect_value(t, escaped("\x7f"), "\"\x7f\"")
}

@(test)
test_non_ascii_stays_raw_utf8 :: proc(t: ^testing.T) {
    // Raw UTF-8, never \uXXXX.
    testing.expect_value(t, escaped("日本語"), `"日本語"`)
    testing.expect_value(t, escaped("é"), `"é"`)
    testing.expect_value(t, escaped("😀"), `"😀"`)
}

@(test)
test_invalid_utf8_becomes_replacement :: proc(t: ^testing.T) {
    // A bad byte must never reach a peer verbatim or as \xNN; it becomes U+FFFD.
    testing.expect_value(t, escaped("\xff"), `"�"`)
    testing.expect_value(t, escaped("a\xe4b"), `"a�b"`)
}

@(test)
test_real_replacement_char_passes_through :: proc(t: ^testing.T) {
    // A real U+FFFD is valid and passes through unchanged.
    testing.expect_value(t, escaped("�"), `"�"`)
}
