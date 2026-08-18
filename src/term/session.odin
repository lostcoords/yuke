package term

import "core:io"
import "core:time"

// Probes carried in one scratch buffer; 512 bytes comfortably holds every DECRPM reply
// plus the Kitty and DA1 responses.
MAX_PROBE_BYTES :: 512

// DECRPM state reported for a DECRQM query. Values are the wire status codes so the
// enum can be produced directly from a parsed report.
Mode_Status :: enum {
    Not_Recognized    = 0, // 0: mode unsupported
    Set               = 1, // 1: currently on
    Reset             = 2, // 2: currently off
    Permanently_Set   = 3, // 3: on and cannot change
    Permanently_Reset = 4, // 4: off and cannot change (e.g. GNOME Terminal)
}

// Per-mode capabilities the terminal advertised via DECRQM.
Capabilities :: struct {
    // Synchronized output, DEC mode 2026.
    synchronized_output: bool,

    // In-band resize reports, DEC mode 2048.
    in_band_resize:      bool,

    // Bracketed paste, DEC mode 2004.
    bracketed_paste:     bool,

    // SGR extended mouse coordinates, DEC mode 1006.
    mouse_sgr:           bool,

    // Kitty keyboard protocol (queried, not DECRQM).
    kitty_keyboard:      bool,

    // Kitty is reporting each key's associated text (flag 16). Read back from the
    // terminal after the push, because flag 8 routes every key through `CSI u` and a
    // terminal that honors it without flag 16 leaves `Key.text` empty for every key.
    kitty_text:          bool,
}

// Modes to enable on `session_enter`; a requested capability the terminal lacks is
// skipped. Construct from `DEFAULT_OPTIONS` and override fields.
Options :: struct {
    alternate_screen: bool,
    bracketed_paste:  bool,
    kitty_keyboard:   bool,
    mouse:            bool,

    // Probe capabilities via DECRQM before enabling. When false, capabilities are
    // assumed absent.
    negotiate:        bool,

    // Total timeout for the combined DECRQM + Kitty probe (ms).
    query_timeout_ms: i32,
}

// Default `Options`; Odin structs cannot carry per-field defaults.
DEFAULT_OPTIONS :: Options {
    alternate_screen = true,
    bracketed_paste  = true,
    kitty_keyboard   = true,
    mouse            = false,
    negotiate        = true,
    query_timeout_ms = 150,
}

// Exactly what `session_enter` turned on, so `session_leave` disables the same set in
// reverse. Fields are ordered to match the enable order; disable walks them backwards.
Enabled :: struct {
    alternate_screen: bool,
    bracketed_paste:  bool,
    in_band_resize:   bool,
    mouse:            bool,
    mouse_sgr:        bool,
    kitty_keyboard:   bool,
}

// Failure modes of `session_enter`. `None` is success.
Session_Error :: enum {
    None = 0,
    Invalid_Query_Timeout,
    Raw_Mode_Failed,
    Write_Failed,
    Capability_Response_Too_Large,
}

// A live terminal session. Borrows `tty` and `out` (they must outlive it) and owns no
// heap memory.
Session :: struct {
    // Advertised capabilities from negotiation.
    caps:                        Capabilities,

    // @private
    // Borrowed tty handle, used for negotiation reads. Must outlive the session.
    tty:                         Tty_Handle,

    // @private
    // Borrowed mode-write sink. Must outlive the session.
    out:                         io.Writer,

    // @private
    // Saved raw-mode state; `session_leave` restores it.
    raw:                         Raw_Term,

    // @private
    // Pre-enter cursor visibility (DEC mode 25), for presentation restore.
    initial_cursor:              Mode_Status,

    // @private
    // Pre-enter synchronized-output state (DEC mode 2026), for presentation restore.
    initial_synchronized_output: Mode_Status,

    // @private
    // Exactly what enter turned on; leave disables the same set.
    enabled:                     Enabled,

    // @private
    // Saved console-output configuration (Windows: VT-processing mode + code pages),
    // restored last by `session_leave`. Zero-size no-op on POSIX.
    out_mode:                    Output_Mode_State,

    // True between a successful enter and its first leave.
    active:                      bool,
}

// Usable: recognized and not permanently disabled (excludes status 0 and 4).
mode_status_supported :: proc(s: Mode_Status) -> bool {
    switch s {
    case .Set, .Reset, .Permanently_Set:
        return true

    case .Not_Recognized, .Permanently_Reset:
        return false
    }

    return false
}

// Enter raw mode, negotiate capabilities, and enable the supported modes; on failure the
// terminal is restored before returning. Windows takes two handles: `tty` is the console
// INPUT handle, `size_handle` the OUTPUT handle that `out` and `get_size` must target.
session_enter :: proc(
    tty: Tty_Handle,
    size_handle: Tty_Handle,
    out: io.Writer,
    startup_input: ^Reader,
    options: Options,
) -> (
    session: Session,
    err: Session_Error,
) {
    // Validate before touching the terminal so a bad timeout cannot leave raw mode on.
    if options.query_timeout_ms < 0 do return {}, .Invalid_Query_Timeout

    committed := false

    // Console output translation (Windows: VT processing + UTF-8 code pages) before raw
    // mode, so its restore runs last on leave (LIFO). POSIX no-op.
    out_mode := output_mode_enter(size_handle)
    defer if !committed do output_mode_leave(out_mode)

    raw, rerr := enable_raw_mode(tty)
    if rerr != .None do return {}, .Raw_Mode_Failed

    // errdefer analogue (see src/client/session_replica.odin): any failure after raw mode
    // disables what was turned on, flushes, and drops raw mode. The terminal must be clean.
    enabled: Enabled
    defer if !committed {
        restore(out, enabled)
        _ = flush_out(out)
        _ = disable_raw_mode(raw)
    }

    // Negotiate before any screen-mode write, so the probe replies land on the primary
    // screen rather than the alternate one. `negotiate` balances its temporary Kitty push
    // on this same screen before returning.
    negotiated: Negotiated
    if options.negotiate {
        n, nerr := negotiate(tty, out, startup_input, options.query_timeout_ms, options.kitty_keyboard)
        if nerr != .None do return {}, nerr

        negotiated = n
    }

    caps := negotiated_capabilities(negotiated)
    new_enabled, eerr := enable_modes(out, options, negotiated)
    if eerr != .None do return {}, eerr
    enabled = new_enabled

    if flush_out(out) != .None do return {}, .Write_Failed

    committed = true

    // Restore the terminal from a fatal signal (SIGTERM/SIGHUP/…, or the Windows console
    // close/logoff/shutdown), the paths that never reach `session_leave`. `size_handle` is
    // the terminal the escape blob is written to.
    signal_restore_arm(size_handle, raw, out_mode)

    return Session {
            caps = caps,
            tty = tty,
            out = out,
            raw = raw,
            initial_cursor = negotiated.cursor,
            initial_synchronized_output = negotiated.synchronized_output,
            enabled = enabled,
            out_mode = out_mode,
            active = true,
        },
        .None
}

// Restore the terminal: disable every mode `session_enter` turned on (reverse order),
// restore presentation modes to the pre-enter snapshot, drop raw mode. Best-effort and
// idempotent: `active` is cleared after the first leave.
session_leave :: proc(s: ^Session) {
    assert(s != nil, "session_leave needs a session")

    if !s.active do return

    restore(s.out, s.enabled)
    restore_presentation(s.out, s.initial_cursor, s.initial_synchronized_output)
    _ = flush_out(s.out)
    _ = disable_raw_mode(s.raw)
    output_mode_leave(s.out_mode)

    // Disarm last: kept armed through the restore writes above so a signal mid-leave still
    // gets a full handler restore before re-raising.
    signal_restore_disarm()

    s.enabled = {}
    s.out_mode = {}
    s.active = false
}

// Enable terminal modes in their lifetime order. Kitty is last so its screen-local stack
// entry belongs to the screen selected above and is the first thing `restore` pops.
enable_modes :: proc(
    out: io.Writer,
    options: Options,
    negotiated: Negotiated,
) -> (
    enabled: Enabled,
    err: Session_Error,
) {
    // The two enable gates differ: alt-screen and mouse tracking predate DECRQM, so they
    // enable whenever the mode is off OR unqueryable (`unprobed_mode_needs_enable`).
    // Bracketed paste and in-band resize enable only on a positive `.Reset`.
    if options.alternate_screen && unprobed_mode_needs_enable(negotiated.alternate_screen) {
        write_out(out, ALT_SCREEN_ENTER) or_return
        enabled.alternate_screen = true
    }

    if options.bracketed_paste && negotiated.bracketed_paste == .Reset {
        write_out(out, BRACKETED_PASTE_ENABLE) or_return
        enabled.bracketed_paste = true
    }

    // In-band resize is not gated by an option: always attempted when the mode is off.
    if negotiated.in_band_resize == .Reset {
        write_out(out, IN_BAND_RESIZE_ENABLE) or_return
        enabled.in_band_resize = true
    }

    if options.mouse && unprobed_mode_needs_enable(negotiated.mouse) {
        write_out(out, MOUSE_TRACKING_ENABLE) or_return
        enabled.mouse = true
    }

    // Only meaningful alongside tracking, and takes tracking's looser gate.
    if enabled.mouse && unprobed_mode_needs_enable(negotiated.mouse_sgr) {
        write_out(out, MOUSE_SGR_ENABLE) or_return
        enabled.mouse_sgr = true
    }

    if options.kitty_keyboard && negotiated.kitty_keyboard {
        write_out(out, KITTY_PUSH_FLAGS) or_return
        enabled.kitty_keyboard = true
    }

    return enabled, .None
}

// Disable the enabled modes in reverse order of enabling. Writes only, best-effort; the
// caller flushes.
restore :: proc(out: io.Writer, enabled: Enabled) {
    if enabled.kitty_keyboard do _, _ = io.write_string(out, KITTY_POP)

    if enabled.mouse_sgr do _, _ = io.write_string(out, MOUSE_SGR_DISABLE)

    if enabled.mouse do _, _ = io.write_string(out, MOUSE_TRACKING_DISABLE)

    if enabled.in_band_resize do _, _ = io.write_string(out, IN_BAND_RESIZE_DISABLE)

    if enabled.bracketed_paste do _, _ = io.write_string(out, BRACKETED_PASTE_DISABLE)

    if enabled.alternate_screen do _, _ = io.write_string(out, ALT_SCREEN_EXIT)
}

// Restore presentation modes to what the terminal reported at startup: a renderer may
// have hidden the cursor or left a synchronized update open. Permanent states cannot be
// changed and are left untouched.
restore_presentation :: proc(out: io.Writer, cursor, synchronized_output: Mode_Status) {
    switch synchronized_output {
    case .Set:
        _, _ = io.write_string(out, SYNC_UPDATE_BEGIN)

    case .Reset:
        _, _ = io.write_string(out, SYNC_UPDATE_END)

    case .Not_Recognized, .Permanently_Set, .Permanently_Reset:
    // Untouched: nothing observed, or the state is permanent.
    }

    switch cursor {
    case .Reset:
        _, _ = io.write_string(out, CURSOR_HIDE)

    case .Set:
        _, _ = io.write_string(out, CURSOR_SHOW)

    case .Not_Recognized:
        // Showing is the conventional safe fallback when mode 25 could not be queried.
        _, _ = io.write_string(out, CURSOR_SHOW)

    case .Permanently_Set, .Permanently_Reset:
    // Permanent states cannot be changed.
    }
}

// Per-mode DECRQM results plus the Kitty query reply. Zero value is all
// `.Not_Recognized` / kitty off, matching a terminal that answered nothing.
Negotiated :: struct {
    cursor:              Mode_Status,
    alternate_screen:    Mode_Status,
    synchronized_output: Mode_Status,
    in_band_resize:      Mode_Status,
    bracketed_paste:     Mode_Status,
    mouse:               Mode_Status,
    mouse_sgr:           Mode_Status,
    kitty_keyboard:      bool,

    // Flags in force after the push, read back from the terminal rather than assumed.
    kitty_flags:         u8,
}

// Collapse the raw per-mode reports into the advertised capability set.
negotiated_capabilities :: proc(n: Negotiated) -> Capabilities {
    return Capabilities {
        synchronized_output = mode_status_supported(n.synchronized_output),
        in_band_resize = mode_status_supported(n.in_band_resize),
        bracketed_paste = mode_status_supported(n.bracketed_paste),
        mouse_sgr = mode_status_supported(n.mouse_sgr),
        kitty_keyboard = n.kitty_keyboard,
        kitty_text = n.kitty_flags & KITTY_FLAG_ASSOCIATED_TEXT != 0,
    }
}

// Whether a pre-DECRQM mode (alt-screen, mouse) should be enabled: yes when the terminal
// reports it off or gives no answer, no when it is already on or permanently fixed.
// Looser than the `.Reset`-only gate used for paste/resize.
unprobed_mode_needs_enable :: proc(s: Mode_Status) -> bool {
    switch s {
    case .Reset, .Not_Recognized:
        return true

    case .Set, .Permanently_Set, .Permanently_Reset:
        return false
    }

    return false
}

// Send every probe in one batch, then read replies until the DA1 sentinel arrives, the
// deadline passes, or EOF. Non-probe bytes are pushed back into `startup_input`. The
// timeout is one total monotonic deadline, not a fresh timeout per byte.
negotiate :: proc(
    tty: Tty_Handle,
    out: io.Writer,
    startup_input: ^Reader,
    timeout_ms: i32,
    push_kitty: bool,
) -> (
    result: Negotiated,
    err: Session_Error,
) {
    kitty_pushed := false
    kitty_popped := false
    defer if kitty_pushed && !kitty_popped {
        _, _ = io.write_string(out, KITTY_POP)
        _ = flush_out(out)
    }

    // One batched write: DECRQM for each mode, the Kitty push, the Kitty query, then DA1
    // as the end-sentinel whose reply follows all the others.
    buf: [16]u8
    write_out(out, decrqm_request(buf[:], 25)) or_return
    write_out(out, decrqm_request(buf[:], 1049)) or_return
    write_out(out, decrqm_request(buf[:], 2026)) or_return
    write_out(out, decrqm_request(buf[:], 2048)) or_return
    write_out(out, decrqm_request(buf[:], 2004)) or_return
    write_out(out, decrqm_request(buf[:], 1003)) or_return
    write_out(out, decrqm_request(buf[:], 1006)) or_return

    // The push goes before the query so the reply reports the flags actually in force. A
    // terminal without the protocol ignores both and creates no stack entry to pop.
    if push_kitty {
        write_out(out, KITTY_PUSH_FLAGS) or_return
        kitty_pushed = true
    }

    write_out(out, KITTY_QUERY) or_return
    write_out(out, DA1_REQUEST) or_return

    if flush_out(out) != .None do return {}, .Write_Failed

    scratch: [MAX_PROBE_BYTES]u8
    n := 0
    start := time.tick_now()
    budget_ns := i64(timeout_ms) * i64(time.Millisecond)

    for n < len(scratch) {
        // One shared deadline: recompute the remaining budget each byte rather than
        // resetting the timeout per read.
        poll_ms: i32
        if timeout_ms == 0 {
            poll_ms = 0
        } else {
            remaining_ns := budget_ns - i64(time.tick_since(start))
            if remaining_ns <= 0 do break

            rounded_ms := (remaining_ns + i64(time.Millisecond) - 1) / i64(time.Millisecond)
            poll_ms = i32(min(rounded_ms, i64(max(i32))))
        }

        if !poll_readable(tty, poll_ms) do break

        b, ok := read_byte(tty)
        if !ok do break // EOF

        scratch[n] = b
        n += 1

        if has_da_response(scratch[:n]) do break
    }

    received := scratch[:n]

    // Kitty keyboard stacks are independent per main/alternate screen. Balance the probe
    // push before `session_enter` can switch screens; the selected screen gets its own push
    // later in `enable_modes`.
    if kitty_pushed {
        write_out(out, KITTY_POP) or_return
        kitty_popped = true
        if flush_out(out) != .None do return {}, .Write_Failed
    }

    kitty_flags, kitty_ok := kitty_query_reply(received)
    result = Negotiated {
        cursor              = parse_mode_report(received, 25),
        alternate_screen    = parse_mode_report(received, 1049),
        synchronized_output = parse_mode_report(received, 2026),
        in_band_resize      = parse_mode_report(received, 2048),
        bracketed_paste     = parse_mode_report(received, 2004),
        mouse               = parse_mode_report(received, 1003),
        mouse_sgr           = parse_mode_report(received, 1006),
        kitty_keyboard      = kitty_ok,
        kitty_flags         = kitty_flags,
    }

    // Preserve real keystrokes typed during the probe window. Best-effort: the scratch is
    // well under the reader's push limit, so only OOM can fail, and dropping a keystroke
    // must not abort entering the terminal.
    _ = preserve_non_probe_input(startup_input, received)

    // A full scratch with no DA1 reply means the replies overran the buffer.
    if n == len(scratch) && !has_da_response(received) do return {}, .Capability_Response_Too_Large

    return result, .None
}

// Minimal CSI scanner: from `start`, require `ESC [`, then skip params/intermediates
// (0x20..0x3f) up to a final byte (0x40..0x7e). Returns the index one past the final
// byte. `ok` is false if `start` is not a CSI or the sequence is incomplete.
csi_end :: proc(bytes: []u8, start: int) -> (int, bool) {
    if start + 2 > len(bytes) || bytes[start] != 0x1b || bytes[start + 1] != '[' do return 0, false

    i := start + 2
    for i < len(bytes) {
        b := bytes[i]
        if b >= 0x40 && b <= 0x7e do return i + 1, true

        if b < 0x20 || b > 0x3f do return 0, false

        i += 1
    }

    return 0, false
}

// True once `bytes` contains any complete CSI ending in the DA1 final byte 'c'. Used as
// the negotiation end-sentinel: a partial `\x1b[?64;1` does not count.
has_da_response :: proc(bytes: []u8) -> bool {
    i := 0
    for i + 1 < len(bytes) {
        end, ok := csi_end(bytes, i)
        if !ok {
            i += 1
            continue
        }

        if bytes[end - 1] == 'c' do return true

        i = end
    }

    return false
}

// Scan `bytes` for a DECRPM reply `CSI ? <mode> ; <status> $ y`. A missing reply, a
// different mode, or status 0 yields `.Not_Recognized`.
parse_mode_report :: proc(bytes: []u8, mode: u16) -> Mode_Status {
    i := 0
    for i + 3 < len(bytes) {
        if bytes[i] != 0x1b || bytes[i + 1] != '[' || bytes[i + 2] != '?' {
            i += 1
            continue
        }

        j := i + 3
        m: u32 = 0
        got_mode := false
        mode_overflow := false
        for j < len(bytes) && bytes[j] >= '0' && bytes[j] <= '9' {
            digit := u32(bytes[j] - '0')
            if m > (max(u32) - digit) / 10 {
                mode_overflow = true
            } else if !mode_overflow do m = m * 10 + digit
            got_mode = true
            j += 1
        }

        if !got_mode || mode_overflow || m != u32(mode) || j >= len(bytes) || bytes[j] != ';' {
            i += 1
            continue
        }

        j += 1
        s: u32 = 0
        got_status := false
        status_overflow := false
        for j < len(bytes) && bytes[j] >= '0' && bytes[j] <= '9' {
            digit := u32(bytes[j] - '0')
            if s > (max(u32) - digit) / 10 {
                status_overflow = true
            } else if !status_overflow do s = s * 10 + digit
            got_status = true
            j += 1
        }

        if !got_status || status_overflow || j + 1 >= len(bytes) || bytes[j] != '$' || bytes[j + 1] != 'y' {
            i += 1
            continue
        }

        switch s {
        case 1:
            return .Set

        case 2:
            return .Reset

        case 3:
            return .Permanently_Set

        case 4:
            return .Permanently_Reset

        case:
            return .Not_Recognized
        }
    }

    return .Not_Recognized
}

// Find the Kitty reply `CSI ? <flags> u` in `bytes` (a DA1 `CSI ? ... c` is not a match).
// `ok` is false when no reply is present. Walks complete CSI blocks rather than anchoring
// on the first `?`, which may belong to a preceding DECRPM report.
kitty_query_reply :: proc(bytes: []u8) -> (u8, bool) {
    i := 0
    for i + 1 < len(bytes) {
        end, ok := csi_end(bytes, i)
        if !ok {
            i += 1
            continue
        }

        if bytes[i + 2] == '?' && bytes[end - 1] == 'u' {
            flags, flags_ok := kitty_flags_response(bytes[i:end])
            if flags_ok do return flags, true
        }

        i = end
    }

    return 0, false
}

// Parse a Kitty query response `CSI ? <flags> u` into its flags bitmask. `ok` is false if
// the shape does not match or the value cannot be a flag set — the field is only five
// bits wide, so anything past `max(u8)` is a malformed reply, not a truncated one.
kitty_flags_response :: proc(bytes: []u8) -> (u8, bool) {
    if len(bytes) < 4 do return 0, false

    if bytes[0] != 0x1b || bytes[1] != '[' || bytes[2] != '?' do return 0, false

    if bytes[len(bytes) - 1] != 'u' do return 0, false

    flags: u32 = 0
    for b in bytes[3:len(bytes) - 1] {
        if b < '0' || b > '9' do return 0, false

        flags = flags * 10 + u32(b - '0')
        if flags > u32(max(u8)) do return 0, false
    }

    return u8(flags), true
}

// True if `sequence` (one complete CSI) is a probe reply: DA1 (`... c`), a Kitty query
// reply (`? ... u`), or a DECRPM report (`? ... $ y`). Everything else is real input.
is_probe_response :: proc(sequence: []u8) -> bool {
    if len(sequence) < 3 do return false

    switch sequence[len(sequence) - 1] {
    case 'c':
        return true // DA1

    case 'u':
        return sequence[2] == '?' // Kitty flags reply

    case 'y':
        // DECRPM: `CSI ? ... $ y`.
        return sequence[2] == '?' && len(sequence) >= 5 && sequence[len(sequence) - 2] == '$'

    case:
        return false
    }
}

// Walk `bytes`, excise exactly the probe-reply CSI sequences, and push every other byte
// run into `input` so keystrokes typed during the probe window survive in order.
preserve_non_probe_input :: proc(input: ^Reader, bytes: []u8) -> Reader_Error {
    keep_start := 0
    i := 0
    for i + 1 < len(bytes) {
        if bytes[i] == 0x1b && bytes[i + 1] == '[' {
            if end, ok := csi_end(bytes, i); ok {
                if is_probe_response(bytes[i:end]) {
                    if keep_start < i {
                        if err := reader_push(input, bytes[keep_start:i]); err != .None do return err
                    }

                    keep_start = end
                }

                i = end
                continue
            }
        }

        i += 1
    }

    if keep_start < len(bytes) {
        if err := reader_push(input, bytes[keep_start:]); err != .None do return err
    }

    return .None
}

// Write a mode string, mapping any write failure to `.Write_Failed` for `or_return`.
write_out :: proc(out: io.Writer, s: string) -> Session_Error {
    if _, err := io.write_string(out, s); err != .None do return .Write_Failed

    return .None
}

// Flush, treating "flush unsupported" as success: the test string-builder sink has no
// flush. Any other error is a real write failure.
flush_out :: proc(out: io.Writer) -> io.Error {
    err := io.flush(out)
    if err == .Unsupported do return .None

    return err
}
