package term

import "core:fmt"

ALT_SCREEN_ENTER :: "\x1b[?1049h"
ALT_SCREEN_EXIT :: "\x1b[?1049l"

BRACKETED_PASTE_ENABLE :: "\x1b[?2004h"
BRACKETED_PASTE_DISABLE :: "\x1b[?2004l"

IN_BAND_RESIZE_ENABLE :: "\x1b[?2048h"
IN_BAND_RESIZE_DISABLE :: "\x1b[?2048l"

MOUSE_TRACKING_ENABLE :: "\x1b[?1003h"
MOUSE_TRACKING_DISABLE :: "\x1b[?1003l"

SYNC_UPDATE_BEGIN :: "\x1b[?2026h"
SYNC_UPDATE_END :: "\x1b[?2026l"

CURSOR_SHOW :: "\x1b[?25h"
CURSOR_HIDE :: "\x1b[?25l"

KITTY_QUERY :: "\x1b[?u"
KITTY_POP :: "\x1b[<u"

// Push Kitty keyboard flags `disambiguate (1) | report_events (2) = 3`. The session
// layer only ever pushes this one combination, so it's a plain constant rather than
// a flags abstraction built for a single caller.
KITTY_PUSH_DISAMBIGUATE_REPORT_EVENTS :: "\x1b[>3u"

DA1_REQUEST :: "\x1b[c"

// Format a DECRQM query (`CSI ? mode $ p`) for a private mode into `buf`. The only
// parameterized escape sequence; kept allocation-free via a caller-supplied buffer.
decrqm_request :: proc(buf: []u8, mode: u16) -> string {
    return fmt.bprintf(buf, "\x1b[?%d$p", mode)
}
