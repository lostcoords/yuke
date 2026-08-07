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

// SGR extended coordinates. Orthogonal to 1003, which picks which events are reported.
// Without it coordinates stop at cell 223 and a release never names its button.
MOUSE_SGR_ENABLE :: "\x1b[?1006h"
MOUSE_SGR_DISABLE :: "\x1b[?1006l"

SYNC_UPDATE_BEGIN :: "\x1b[?2026h"
SYNC_UPDATE_END :: "\x1b[?2026l"

CURSOR_SHOW :: "\x1b[?25h"
CURSOR_HIDE :: "\x1b[?25l"

KITTY_QUERY :: "\x1b[?u"
KITTY_POP :: "\x1b[<u"

// Unconditional full restore, emitted from a fatal-signal handler where the per-session
// `Enabled` set is not reachable. Every disable is a no-op when its mode is already off, so
// the fixed blob is safe regardless of what the session turned on. Order mirrors `restore`
// (Kitty popped first, alt screen exited last) then presentation: end any sync update and
// show the cursor, the safe emergency default.
SIGNAL_RESTORE_ALL: string :
    KITTY_POP +
    MOUSE_SGR_DISABLE +
    MOUSE_TRACKING_DISABLE +
    IN_BAND_RESIZE_DISABLE +
    BRACKETED_PASTE_DISABLE +
    ALT_SCREEN_EXIT +
    SYNC_UPDATE_END +
    CURSOR_SHOW

// Kitty keyboard flags. Alternates and text only reach keys that take the escape path, so
// the set is pushed whole — but a terminal silently keeps only the bits it implements,
// which is why the push is followed by a query rather than trusted.
KITTY_FLAG_DISAMBIGUATE :: u8(1)
KITTY_FLAG_EVENT_TYPES :: u8(2)
KITTY_FLAG_ALTERNATE_KEYS :: u8(4)
KITTY_FLAG_ALL_KEYS_ESCAPED :: u8(8)
KITTY_FLAG_ASSOCIATED_TEXT :: u8(16)

KITTY_FLAGS_WANTED ::
    KITTY_FLAG_DISAMBIGUATE |
    KITTY_FLAG_EVENT_TYPES |
    KITTY_FLAG_ALTERNATE_KEYS |
    KITTY_FLAG_ALL_KEYS_ESCAPED |
    KITTY_FLAG_ASSOCIATED_TEXT
#assert(KITTY_FLAGS_WANTED == 31)

KITTY_PUSH_FLAGS :: "\x1b[>31u"

DA1_REQUEST :: "\x1b[c"

// Format a DECRQM query (`CSI ? mode $ p`) for a private mode into `buf`. The only
// parameterized escape sequence; kept allocation-free via a caller-supplied buffer.
decrqm_request :: proc(buf: []u8, mode: u16) -> string {
    return fmt.bprintf(buf, "\x1b[?%d$p", mode)
}
