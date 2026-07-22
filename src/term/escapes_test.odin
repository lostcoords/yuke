package term

import "core:testing"

@(test)
test_escape_constants_exact_bytes :: proc(t: ^testing.T) {
    testing.expect_value(t, ALT_SCREEN_ENTER, "\x1b[?1049h")
    testing.expect_value(t, ALT_SCREEN_EXIT, "\x1b[?1049l")

    testing.expect_value(t, BRACKETED_PASTE_ENABLE, "\x1b[?2004h")
    testing.expect_value(t, BRACKETED_PASTE_DISABLE, "\x1b[?2004l")

    testing.expect_value(t, IN_BAND_RESIZE_ENABLE, "\x1b[?2048h")
    testing.expect_value(t, IN_BAND_RESIZE_DISABLE, "\x1b[?2048l")

    testing.expect_value(t, MOUSE_TRACKING_ENABLE, "\x1b[?1003h")
    testing.expect_value(t, MOUSE_TRACKING_DISABLE, "\x1b[?1003l")

    testing.expect_value(t, SYNC_UPDATE_BEGIN, "\x1b[?2026h")
    testing.expect_value(t, SYNC_UPDATE_END, "\x1b[?2026l")

    testing.expect_value(t, CURSOR_SHOW, "\x1b[?25h")
    testing.expect_value(t, CURSOR_HIDE, "\x1b[?25l")

    testing.expect_value(t, KITTY_QUERY, "\x1b[?u")
    testing.expect_value(t, KITTY_POP, "\x1b[<u")
    testing.expect_value(t, KITTY_PUSH_DISAMBIGUATE_REPORT_EVENTS, "\x1b[>3u")

    testing.expect_value(t, DA1_REQUEST, "\x1b[c")
}

@(test)
test_decrqm_request_formats_mode :: proc(t: ^testing.T) {
    buf: [32]u8
    testing.expect_value(t, decrqm_request(buf[:], 2026), "\x1b[?2026$p")
    testing.expect_value(t, decrqm_request(buf[:], 1), "\x1b[?1$p")
}
