package term

import "core:io"
import "core:time"

// DECRPM state reported for a DECRQM query. Values are the wire status codes so the
// enum can be produced directly from a parsed report.
Mode_Status :: enum {
    Not_Recognized    = 0, // 0: mode unsupported
    Set               = 1, // 1: currently on
    Reset             = 2, // 2: currently off
    Permanently_Set   = 3, // 3: on and cannot change
    Permanently_Reset = 4, // 4: off and cannot change (e.g. GNOME Terminal)
}

// Per-mode capabilities the terminal advertised via DECRQM. Mode numbers are noted
// per field.
Capabilities :: struct {
    // Synchronized output, DEC mode 2026.
    synchronized_output: bool,

    // In-band resize reports, DEC mode 2048.
    in_band_resize:      bool,

    // Bracketed paste, DEC mode 2004.
    bracketed_paste:     bool,

    // Kitty keyboard protocol (queried, not DECRQM).
    kitty_keyboard:      bool,
}

// Modes to enable on `session_enter`. A requested capability the terminal lacks is
// skipped. Construct from `DEFAULT_OPTIONS` and override fields; Odin has no struct
// field defaults, so defaults live in that constant.
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

// Default `Options` values, expressed as a constant since Odin structs cannot carry
// per-field defaults.
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
// heap memory. `initial_cursor` / `initial_synchronized_output` snapshot what the
// terminal reported for those presentation modes before enter, so leave can restore
// them.
Session :: struct {
    // Advertised capabilities from negotiation.
    caps:                        Capabilities,

    // Borrowed tty handle, used for negotiation reads. Must outlive the session.
    tty:                         Tty_Handle,

    // Borrowed mode-write sink. Must outlive the session.
    out:                         io.Writer,

    // Saved raw-mode state; `session_leave` restores it.
    raw:                         Raw_Term,

    // Pre-enter cursor visibility (DEC mode 25), for presentation restore.
    initial_cursor:              Mode_Status,

    // Pre-enter synchronized-output state (DEC mode 2026), for presentation restore.
    initial_synchronized_output: Mode_Status,

    // Exactly what enter turned on; leave disables the same set.
    enabled:                     Enabled,

    // Saved console-output configuration (Windows: VT-processing mode + code pages),
    // restored last by `session_leave`. Zero-size no-op on POSIX.
    out_mode:                    Output_Mode_State,
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

// Probes carried in one scratch buffer; 512 bytes comfortably holds every DECRPM reply
// plus the Kitty and DA1 responses.
MAX_PROBE_BYTES :: 512

// Enter raw mode, negotiate capabilities, and enable the supported modes. On any
// failure after raw mode is entered the terminal is restored before returning. Call
// once before the event loop: the probe reads replies synchronously.
//
// Windows precondition: `tty` is the console INPUT handle (raw mode + negotiation reads),
// and `out` must write to the process's standard-output console — VT processing is
// enabled on `GetStdHandle(STD_OUTPUT_HANDLE)`, so escapes sent through an `out` backed by
// a different handle would not be interpreted. On POSIX `tty` is the single tty fd.
session_enter :: proc(
    tty: Tty_Handle,
    out: io.Writer,
    startup_input: ^Reader,
    options: Options,
) -> (
    session: Session,
    err: Session_Error,
) {
    // Validate before touching the terminal so a bad timeout cannot leave raw mode on.
    if options.query_timeout_ms < 0 {
        return {}, .Invalid_Query_Timeout
    }

    committed := false

    // Enable console output translation (Windows: VT processing + UTF-8 code pages)
    // before raw mode, so its restore runs last on leave. POSIX no-op. This unwind arm
    // is registered first, so on failure it runs after the raw/mode unwind (LIFO) — the
    // outermost-first pairing.
    out_mode := output_mode_enter()
    defer if !committed {
        output_mode_leave(out_mode)
    }

    raw, rerr := enable_raw_mode(tty)
    if rerr != .None {
        return {}, .Raw_Mode_Failed
    }

    enabled: Enabled

    // errdefer analogue (see src/client/session_replica.odin): any failure after raw
    // mode is entered disables every mode turned on so far in reverse, best-effort
    // flushes, and drops raw mode. The terminal must be clean after a partial failure.
    defer if !committed {
        restore(out, enabled)
        _ = flush_out(out)
        _ = disable_raw_mode(raw)
    }

    // Negotiate before any screen-mode write, so the probe replies land on the primary
    // screen rather than the alternate one.
    negotiated: Negotiated
    if options.negotiate {
        n, nerr := negotiate(tty, out, startup_input, options.query_timeout_ms)
        if nerr != .None {
            return {}, nerr
        }

        negotiated = n
    }

    caps := negotiated_capabilities(negotiated)

    // The two enable gates differ deliberately. Alt-screen and mouse tracking predate
    // DECRQM, so they enable best-effort whenever the mode is off OR unqueryable
    // (`unprobed_mode_needs_enable`). Bracketed paste and in-band resize are only
    // enabled on a positive `.Reset` confirmation that the mode exists and is off.
    if options.alternate_screen && unprobed_mode_needs_enable(negotiated.alternate_screen) {
        write_out(out, ALT_SCREEN_ENTER) or_return
        enabled.alternate_screen = true
    }

    if options.bracketed_paste && negotiated.bracketed_paste == .Reset {
        write_out(out, BRACKETED_PASTE_ENABLE) or_return
        enabled.bracketed_paste = true
    }

    // In-band resize is not gated by any option: it is always attempted when the
    // terminal confirms the mode is off.
    if negotiated.in_band_resize == .Reset {
        write_out(out, IN_BAND_RESIZE_ENABLE) or_return
        enabled.in_band_resize = true
    }

    if options.mouse && unprobed_mode_needs_enable(negotiated.mouse) {
        write_out(out, MOUSE_TRACKING_ENABLE) or_return
        enabled.mouse = true
    }

    if options.kitty_keyboard && caps.kitty_keyboard {
        write_out(out, KITTY_PUSH_DISAMBIGUATE_REPORT_EVENTS) or_return
        enabled.kitty_keyboard = true
    }

    if flush_out(out) != .None {
        return {}, .Write_Failed
    }

    committed = true

    return Session {
            caps = caps,
            tty = tty,
            out = out,
            raw = raw,
            initial_cursor = negotiated.cursor,
            initial_synchronized_output = negotiated.synchronized_output,
            enabled = enabled,
            out_mode = out_mode,
        },
        .None
}

// Restore the terminal: disable every mode `session_enter` turned on (reverse order),
// restore presentation modes to the pre-enter snapshot, drop raw mode. Best-effort and
// idempotent: after the first call `enabled` is cleared, so a second call disables
// nothing.
session_leave :: proc(s: ^Session) {
    restore(s.out, s.enabled)
    restore_presentation(s.out, s.initial_cursor, s.initial_synchronized_output)
    _ = flush_out(s.out)
    _ = disable_raw_mode(s.raw)
    output_mode_leave(s.out_mode)
    s.enabled = {}
    s.out_mode = {}
}

// Disable the enabled modes in reverse order of enabling. Writes only, best-effort; the
// caller flushes.
restore :: proc(out: io.Writer, enabled: Enabled) {
    if enabled.kitty_keyboard {
        write_swallow(out, KITTY_POP)
    }

    if enabled.mouse {
        write_swallow(out, MOUSE_TRACKING_DISABLE)
    }

    if enabled.in_band_resize {
        write_swallow(out, IN_BAND_RESIZE_DISABLE)
    }

    if enabled.bracketed_paste {
        write_swallow(out, BRACKETED_PASTE_DISABLE)
    }

    if enabled.alternate_screen {
        write_swallow(out, ALT_SCREEN_EXIT)
    }
}

// Restore presentation modes to what the terminal reported at startup. A renderer
// running between enter and leave may have hidden the cursor or left a synchronized
// update open; this puts both back to the pre-enter snapshot. Permanent states cannot
// be changed and are left untouched.
restore_presentation :: proc(out: io.Writer, cursor, synchronized_output: Mode_Status) {
    switch synchronized_output {
    case .Set:
        write_swallow(out, SYNC_UPDATE_BEGIN)

    case .Reset:
        write_swallow(out, SYNC_UPDATE_END)

    case .Not_Recognized, .Permanently_Set, .Permanently_Reset:
    // Untouched: nothing observed, or the state is permanent.
    }

    switch cursor {
    case .Reset:
        write_swallow(out, CURSOR_HIDE)

    case .Set:
        write_swallow(out, CURSOR_SHOW)

    case .Not_Recognized:
        // Showing is the conventional safe fallback when mode 25 could not be queried.
        write_swallow(out, CURSOR_SHOW)

    case .Permanently_Set, .Permanently_Reset:
    // Permanent states cannot be changed.
    }
}

// Per-mode DECRQM results plus the Kitty support flag. Zero value is all
// `.Not_Recognized` / kitty off, matching a terminal that answered nothing.
Negotiated :: struct {
    cursor:              Mode_Status,
    alternate_screen:    Mode_Status,
    synchronized_output: Mode_Status,
    in_band_resize:      Mode_Status,
    bracketed_paste:     Mode_Status,
    mouse:               Mode_Status,
    kitty_keyboard:      bool,
}

// Collapse the raw per-mode reports into the advertised capability set.
negotiated_capabilities :: proc(n: Negotiated) -> Capabilities {
    return Capabilities {
        synchronized_output = mode_status_supported(n.synchronized_output),
        in_band_resize = mode_status_supported(n.in_band_resize),
        bracketed_paste = mode_status_supported(n.bracketed_paste),
        kitty_keyboard = n.kitty_keyboard,
    }
}

// Whether a pre-DECRQM mode (alt-screen, mouse) should be enabled: yes when the
// terminal reports it off (`.Reset`) or gives no answer (`.Not_Recognized`); no when it
// is already on or permanently fixed. This is looser than the positive `.Reset`-only
// gate used for paste/resize.
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
// deadline passes, or EOF. Bytes that are not probe replies are pushed back into
// `startup_input` for the event loop. The timeout is one total monotonic deadline, not
// a fresh timeout per byte.
negotiate :: proc(
    tty: Tty_Handle,
    out: io.Writer,
    startup_input: ^Reader,
    timeout_ms: i32,
) -> (
    result: Negotiated,
    err: Session_Error,
) {
    // One batched write: DECRQM for each mode, the Kitty query, then DA1 as the
    // end-sentinel whose reply follows all the others.
    buf: [16]u8
    write_out(out, decrqm_request(buf[:], 25)) or_return
    write_out(out, decrqm_request(buf[:], 1049)) or_return
    write_out(out, decrqm_request(buf[:], 2026)) or_return
    write_out(out, decrqm_request(buf[:], 2048)) or_return
    write_out(out, decrqm_request(buf[:], 2004)) or_return
    write_out(out, decrqm_request(buf[:], 1003)) or_return
    write_out(out, KITTY_QUERY) or_return
    write_out(out, DA1_REQUEST) or_return

    if flush_out(out) != .None {
        return {}, .Write_Failed
    }

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
            if remaining_ns <= 0 {
                break
            }

            rounded_ms := (remaining_ns + i64(time.Millisecond) - 1) / i64(time.Millisecond)
            poll_ms = i32(min(rounded_ms, i64(max(i32))))
        }

        if !poll_readable(tty, poll_ms) {
            break
        }

        b, ok := read_byte(tty)
        if !ok {
            break // EOF
        }

        scratch[n] = b
        n += 1

        if has_da_response(scratch[:n]) {
            break
        }
    }

    received := scratch[:n]
    result = Negotiated {
        cursor              = parse_mode_report(received, 25),
        alternate_screen    = parse_mode_report(received, 1049),
        synchronized_output = parse_mode_report(received, 2026),
        in_band_resize      = parse_mode_report(received, 2048),
        bracketed_paste     = parse_mode_report(received, 2004),
        mouse               = parse_mode_report(received, 1003),
        kitty_keyboard      = kitty_supported(received),
    }

    // Preserve any real keystrokes typed during the probe window. Best-effort: the
    // scratch is bounded at 512 bytes, well under the reader's push limit, so the only
    // possible failure is OOM, in which case dropping a few pre-session keystrokes is
    // acceptable and must not abort entering the terminal.
    _ = preserve_non_probe_input(startup_input, received)

    // A full scratch with no DA1 reply means the replies overran the buffer.
    if n == len(scratch) && !has_da_response(received) {
        return {}, .Capability_Response_Too_Large
    }

    return result, .None
}

// Minimal CSI scanner: from `start`, require `ESC [`, then skip params/intermediates
// (0x20..0x3f) up to a final byte (0x40..0x7e). Returns the index one past the final
// byte. `ok` is false if `start` is not a CSI or the sequence is incomplete/malformed.
// Deliberately separate from the events.odin parser: this only finds boundaries and
// finals, with no semantic decode.
csi_end :: proc(bytes: []u8, start: int) -> (int, bool) {
    if start + 2 > len(bytes) || bytes[start] != 0x1b || bytes[start + 1] != '[' {
        return 0, false
    }

    i := start + 2
    for i < len(bytes) {
        b := bytes[i]
        if b >= 0x40 && b <= 0x7e {
            return i + 1, true
        }

        if b < 0x20 || b > 0x3f {
            return 0, false
        }

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

        if bytes[end - 1] == 'c' {
            return true
        }

        i = end
    }

    return false
}

// Scan `bytes` for a DECRPM reply `CSI ? <mode> ; <status> $ y` matching `mode`. A
// missing reply, a different mode, or status 0 yields `.Not_Recognized`. Member order
// within the report is fixed by the protocol, so this is a positional scan, not the
// order-independent wire decoder.
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
        for j < len(bytes) && bytes[j] >= '0' && bytes[j] <= '9' {
            m = m * 10 + u32(bytes[j] - '0')
            got_mode = true
            j += 1
        }

        if !got_mode || m != u32(mode) || j >= len(bytes) || bytes[j] != ';' {
            i += 1
            continue
        }

        j += 1
        s: u32 = 0
        got_status := false
        for j < len(bytes) && bytes[j] >= '0' && bytes[j] <= '9' {
            s = s * 10 + u32(bytes[j] - '0')
            got_status = true
            j += 1
        }

        if !got_status || j + 1 >= len(bytes) || bytes[j] != '$' || bytes[j + 1] != 'y' {
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

// True if `bytes` contains a Kitty keyboard reply `CSI ? <flags> u`. A `CSI ? ... c`
// (a DA1 reply) is not a match, so the Kitty reply must actually be present.
//
// The first `?` in the reply buffer may belong to a DECRPM report; anchoring there and
// scanning to the first 'u'/'c' would fail the Kitty check on interior bytes. DECRPM-first
// replies are the norm on real terminals, so walk complete CSI blocks and test each
// `?...u` reply individually.
kitty_supported :: proc(bytes: []u8) -> bool {
    i := 0
    for i + 1 < len(bytes) {
        end, ok := csi_end(bytes, i)
        if !ok {
            i += 1
            continue
        }

        if bytes[i + 2] == '?' && bytes[end - 1] == 'u' {
            _, flags_ok := kitty_flags_response(bytes[i:end])
            if flags_ok {
                return true
            }
        }

        i = end
    }

    return false
}

// Parse a Kitty query response `CSI ? <flags> u` into its flags bitmask. `ok` is false
// if the shape does not match.
kitty_flags_response :: proc(bytes: []u8) -> (u8, bool) {
    if len(bytes) < 4 {
        return 0, false
    }

    if bytes[0] != 0x1b || bytes[1] != '[' || bytes[2] != '?' {
        return 0, false
    }

    if bytes[len(bytes) - 1] != 'u' {
        return 0, false
    }

    flags: u16 = 0
    for b in bytes[3:len(bytes) - 1] {
        if b < '0' || b > '9' {
            return 0, false
        }

        flags = flags * 10 + u16(b - '0')
    }

    return u8(flags), true
}

// True if `sequence` (one complete CSI) is a probe reply: DA1 (`... c`), a Kitty query
// reply (`? ... u`), or a DECRPM report (`? ... $ y`). Everything else is real input.
is_probe_response :: proc(sequence: []u8) -> bool {
    if len(sequence) < 3 {
        return false
    }

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
                        if err := reader_push(input, bytes[keep_start:i]); err != .None {
                            return err
                        }
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
        if err := reader_push(input, bytes[keep_start:]); err != .None {
            return err
        }
    }

    return .None
}

// Write a mode string, mapping any write failure to `.Write_Failed` for `or_return`.
write_out :: proc(out: io.Writer, s: string) -> Session_Error {
    if _, err := io.write_string(out, s); err != .None {
        return .Write_Failed
    }

    return .None
}

// Best-effort mode write used on the restore paths, where errors are swallowed.
write_swallow :: proc(out: io.Writer, s: string) {
    _, _ = io.write_string(out, s)
}

// Flush the writer, treating "flush unsupported" as success. An unbuffered sink (such as
// a test string builder) reports `.Unsupported`, which is not a real failure; anything
// else is a genuine write error.
flush_out :: proc(out: io.Writer) -> io.Error {
    err := io.flush(out)
    if err == .Unsupported {
        return .None
    }

    return err
}
