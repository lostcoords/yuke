package tui

/*
Client host: QuickJS + yuke:term + double-buffered ui paint.

Draw model (lite-xl / rxi):
  beginFrame → fill/text/cursor → endFrame
endFrame runs ui.flush_diff: only cells that differ from the previous frame are
written to the terminal.
*/

import "core:fmt"
import "core:io"
import "core:mem"
import "core:mem/virtual"
import "core:nbio"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "libs:bindings/curl"
import qjs "libs:bindings/quickjs"
import "libs:offload"
import "src:js"
import "src:paths"
import "src:term"
import "src:term/ui"

// The baked default entry the host evaluates, plus the core and default-UI modules it imports.
// Served to the loader by `host_resolve` so the client's own `import "yuke:core"` resolves in
// the binary; user files under the config dir resolve the same way, off disk.
APP_JS :: #load("js/app.js", string)

CORE_JS :: #load("js/core.js", string)

UI_JS :: #load("js/ui.js", string)

DEFAULTS_JS :: #load("js/defaults.js", string)

CLIENT_JS :: #load("js/client.js", string)

// The user config entry, evaluated on top of the baked UI when present.
USER_ENTRY :: "yuke.js"

// Default period when JS omits periodMs (heartbeat-scale).
TICK_MS_DEFAULT :: 450 * time.Millisecond

TICK_MS_MIN :: 50 * time.Millisecond

TICK_MS_MAX :: 2000 * time.Millisecond

// One worker: the TUI's only blocking work is a `yuke:fs` read, and those are user-driven
// rather than concurrent.
FS_WORKERS :: 1

Host :: struct {
    // Runtime, limits, module loading, and `yuke:fs`, shared with the daemon.
    js:               js.Host,

    // Blocking `yuke:fs` passes. Must be drained before `js` is released: an in-flight job
    // owns the settle functions of a live promise in that context.
    pool:             offload.Pool,
    has_pool:         bool,
    on_event:         qjs.Value,
    // Retained `term` export; width/height numbers updated in place on resize.
    term_obj:         qjs.Value,
    // Reused {w,h} for term.size() to avoid per-call object alloc.
    size_obj:         qjs.Value,
    buf:              ui.Buffer,
    has_buf:          bool,
    out:              io.Writer,
    drive:            ^term.Drive,
    sync:             bool,
    // True after any draw into the current grid since last successful endFrame.
    dirty:            bool,
    // True between beginFrame and endFrame (auto begin on first draw if needed).
    in_frame:         bool,
    done:             bool,
    last_err:         string,
    // Owned canonical config directory (`~/.config/yuke`); the containment root for user module
    // files. Empty when no config dir resolves — then only the baked modules load.
    config_root:      string,
    // Owned data directory (`~/.local/share/yuke`); where `yuke login` writes the device identity.
    // Empty when none resolves, which reads as not-enrolled.
    data_root:        string,
    allocator:        mem.Allocator,
    // Cached dimensions for term.width / term.height.
    width:            u16,
    height:           u16,

    // Demand-driven anim ticks (lite-xl-style deadline, not a permanent FPS loop).
    needs_tick:       bool,
    tick_period:      time.Duration,
    tick_op:          ^nbio.Operation,

    // One daemon connection shared by the client script tier. Its request completions own
    // QuickJS promise functions, so it must be closed before `js` is released.
    daemon:           Daemon_Connection,

    // The one session the UI has open, folding live broadcasts into a replica. Torn down when
    // the connection closes and before `js` is released.
    open_session:     Open_Session,

    // Reset per snapshot build; retains its block across polls so a repaint accrues no heap
    // churn. Not the shared temp allocator, which this host never resets per frame.
    snapshot_scratch: virtual.Arena,

    // One in-flight remote (relay) connect attempt, or nil. Owns the control-plane fetch state
    // until it hands a live transport to `daemon`; canceled before `js` is released so its
    // promise settles while the context is alive.
    remote:           ^Remote_Connect,

    // Control-plane HTTP client for remote connects (roster + connect tickets), created on the
    // first remote connect and reused. `client_destroy` may not run in a curl callback, so it
    // is destroyed only at teardown, once idle.
    cloud_curl:       curl.Client,
    cloud_curl_ready: bool,
}

host_init :: proc(
    h: ^Host,
    out: io.Writer,
    drive: ^term.Drive,
    loop: ^nbio.Event_Loop,
    allocator := context.allocator,
) -> bool {
    assert(h != nil && drive != nil, "host_init needs host and drive")
    assert(loop != nil, "host_init needs the event loop the fs pool returns completions to")

    h^ = {}
    h.out = out
    h.drive = drive
    h.allocator = allocator
    h.sync = drive.caps.synchronized_output
    h.on_event = qjs.undefined()
    h.term_obj = qjs.undefined()
    h.size_obj = qjs.undefined()
    h.tick_period = TICK_MS_DEFAULT

    size := drive.size
    if size.width == 0 do size.width = 80
    if size.height == 0 do size.height = 24
    h.width = size.width
    h.height = size.height

    if msg := paths.app_name_error(); msg != "" {
        host_set_last_err(h, msg)
        return false
    }

    buf, berr := ui.buffer_init(allocator, size.width, size.height)
    if berr != .None {
        host_set_last_err(h, fmt.tprintf("buffer_init: %v", berr))
        return false
    }
    h.buf = buf
    h.has_buf = true

    if virtual.arena_init_growing(&h.snapshot_scratch) != nil {
        host_set_last_err(h, "snapshot scratch arena unavailable")
        return false
    }

    if perr := offload.pool_init(&h.pool, loop, FS_WORKERS); perr != .None {
        host_set_last_err(h, fmt.tprintf("fs pool: %v", perr))
        return false
    }

    h.has_pool = true

    // The working directory is the workspace in practice — the client is run from the
    // project it edits — and it is what a relative script path resolves against. When the
    // client gains a daemon connection this becomes the resolved workspace root.
    root, root_err := os.get_working_directory(allocator)
    if root_err != nil {
        host_set_last_err(h, "cannot resolve the working directory")
        return false
    }

    defer delete(root, allocator)

    // The config directory holds `yuke.js` and its plugins; empty when none resolves, which
    // leaves only the baked modules loadable. Not canonicalized against the filesystem: it is
    // the exact string the user-module names are built from, so containment stays a byte-prefix
    // test rather than depending on the directory existing yet.
    h.config_root = paths.config_dir(allocator)
    h.data_root = paths.data_dir(allocator)

    modules := [5]js.Module{js.fs_module(), js.exec_module(), js.diff_module(), term_module(), client_module()}

    // 16 MiB rather than the shared default: a TUI's scripts are widgets and keymaps, and
    // anything approaching this is a runaway. The deadline is deliberately the shared one —
    // work that legitimately runs that long is intentional, and a freeze past it is a bug
    // the user is watching happen.
    options := js.Options {
        modules      = modules[:],
        base         = root,
        pool         = &h.pool,
        user         = h,
        report       = host_report,
        resolve      = host_resolve,
        memory_limit = 16 * mem.Megabyte,
        allocator    = allocator,
    }

    switch js.init(&h.js, options) {
    case .None:

    case .Invalid_Root:
        host_set_last_err(h, "working directory is not a usable base")
        return false
    }

    // Reused size object for term.size().
    h.size_obj = qjs.new_object(h.js.ctx)
    _ = qjs.set_property(h.js.ctx, h.size_obj, "w", qjs.new_i32(i32(h.width)))
    _ = qjs.set_property(h.js.ctx, h.size_obj, "h", qjs.new_i32(i32(h.height)))

    if !host_eval_app(h) do return false

    return true
}

host_destroy :: proc(h: ^Host) {
    if h == nil do return

    host_cancel_tick(h)
    h.needs_tick = false
    h.done = true

    // Settle any in-flight remote connect while the context is still alive, then drop the
    // control-plane client (idle now that its transfer is canceled).
    remote_connect_cancel(h)
    if h.cloud_curl_ready {
        curl.client_destroy(&h.cloud_curl)
        h.cloud_curl_ready = false
    }

    daemon_connection_destroy(h)

    // Before anything releases the context: draining runs every outstanding `yuke:fs`
    // completion on this loop, and each one settles a promise that lives in it. Freeing
    // first would settle into freed memory. Every teardown path reaches here, including the
    // error branches in `main`, which is exactly when a read is most likely still in
    // flight.
    if h.has_pool {
        if derr := offload.pool_drain(&h.pool); derr != nil do assert(derr == nil, "the fs pool did not drain")

        offload.pool_destroy(&h.pool)
        h.has_pool = false
    }

    if h.js.ctx != nil {
        if !qjs.is_undefined(h.on_event) {
            qjs.free_value(h.js.ctx, h.on_event)
            h.on_event = qjs.undefined()
        }
        if !qjs.is_undefined(h.size_obj) {
            qjs.free_value(h.js.ctx, h.size_obj)
            h.size_obj = qjs.undefined()
        }
        if !qjs.is_undefined(h.term_obj) {
            qjs.free_value(h.js.ctx, h.term_obj)
            h.term_obj = qjs.undefined()
        }
    }

    js.destroy(&h.js)

    virtual.arena_check_temp(&h.snapshot_scratch)
    virtual.arena_destroy(&h.snapshot_scratch)

    if h.has_buf {
        ui.buffer_destroy(&h.buf)
        h.has_buf = false
    }

    if h.last_err != "" {
        delete(h.last_err, h.allocator)
        h.last_err = ""
    }

    if h.config_root != "" {
        delete(h.config_root, h.allocator)
        h.config_root = ""
    }

    if h.data_root != "" {
        delete(h.data_root, h.allocator)
        h.data_root = ""
    }
}

host_set_last_err :: proc(h: ^Host, msg: string) {
    if h.last_err != "" {
        delete(h.last_err, h.allocator)
        h.last_err = ""
    }
    if msg != "" do h.last_err = strings.clone(msg, h.allocator)
}

host_dispatch :: proc(h: ^Host, obj: qjs.Value) {
    if qjs.is_undefined(h.on_event) do return

    args := [1]qjs.Value{obj}
    result, ok := js.call(&h.js, h.on_event, qjs.undefined(), args[:], "onEvent")

    if !ok {
        // Fail closed: do not keep animating after a fatal paint/event error.
        h.needs_tick = false
        host_cancel_tick(h)
        return
    }

    defer qjs.free_value(h.js.ctx, result)

    js.drain(&h.js)
    // Commit any frame left open by script (or auto-drawn without endFrame).
    if h.dirty do host_end_frame(h)
}

host_on_term_event :: proc(h: ^Host, ev: term.Event) {
    assert(h != nil && h.js.ctx != nil, "host_on_term_event needs a live host")

    if h.done do return

    if closed, is_closed := ev.(term.Input_Closed); is_closed {
        host_on_input_closed(h, closed.reason)
        return
    }

    // Resize buffer before JS sees the event.
    if _, is_resize := ev.(term.Resize); is_resize {
        size := h.drive.size
        host_resize_buffer(h, size.width, size.height)
    }

    obj := host_event_object(h, ev)
    defer qjs.free_value(h.js.ctx, obj)

    if qjs.is_undefined(h.on_event) {
        if k, ok := ev.(term.Key); ok {
            // Kitty names the unshifted 'q'; a legacy terminal reports the glyph typed.
            if k.event != .Release && k.code == .Char && (k.char == 'q' || k.char == 'Q') do h.done = true
        }
        return
    }

    host_dispatch(h, obj)
}

host_on_input_closed :: proc(h: ^Host, reason: term.Input_Closed_Reason) {
    // Drop ticks before dispatch so a late setNeedsTick(true) during quit paint
    // cannot re-arm after we mark done.
    h.needs_tick = false
    host_cancel_tick(h)

    obj := qjs.new_object(h.js.ctx)
    _ = qjs.set_property(h.js.ctx, obj, "type", qjs.new_string(h.js.ctx, "input_closed"))
    _ = qjs.set_property(h.js.ctx, obj, "reason", qjs.new_string(h.js.ctx, input_closed_wire(reason)))
    defer qjs.free_value(h.js.ctx, obj)

    host_dispatch(h, obj)
    h.done = true
}

input_closed_wire :: proc(r: term.Input_Closed_Reason) -> string {
    switch r {
    case .None:
        return "none"
    case .Peer_EOF:
        return "peer_eof"
    case .Recv_Error:
        return "recv_error"
    case .Reader_Failed:
        return "reader_failed"
    }
    return "unknown"
}

host_event_object :: proc(h: ^Host, ev: term.Event) -> qjs.Value {
    obj := qjs.new_object(h.js.ctx)

    switch e in ev {
    case term.Key:
        key := e
        _ = qjs.set_property(h.js.ctx, obj, "type", qjs.new_string(h.js.ctx, "key"))
        _ = qjs.set_property(h.js.ctx, obj, "code", qjs.new_string(h.js.ctx, term.key_code_names[key.code]))
        _ = qjs.set_property(h.js.ctx, obj, "event", qjs.new_string(h.js.ctx, term.key_event_names[key.event]))
        _ = qjs.set_property(h.js.ctx, obj, "char", host_rune_value(h, key.char))
        _ = qjs.set_property(h.js.ctx, obj, "shifted", host_rune_value(h, key.shifted))
        _ = qjs.set_property(h.js.ctx, obj, "baseLayout", host_rune_value(h, key.base_layout))
        _ = qjs.set_property(h.js.ctx, obj, "text", qjs.new_string(h.js.ctx, term.key_text(&key)))
        _ = qjs.set_property(h.js.ctx, obj, "mods", qjs.new_i32(i32(transmute(u8)key.mods)))
        _ = qjs.set_property(h.js.ctx, obj, "locks", qjs.new_i32(i32(transmute(u8)key.locks)))

    case term.Paste:
        _ = qjs.set_property(h.js.ctx, obj, "type", qjs.new_string(h.js.ctx, "paste"))
        _ = qjs.set_property(h.js.ctx, obj, "len", qjs.new_i32(i32(len(e.text))))
        _ = qjs.set_property(h.js.ctx, obj, "truncated", qjs.new_bool(e.truncated))

    case term.Resize:
        _ = qjs.set_property(h.js.ctx, obj, "type", qjs.new_string(h.js.ctx, "resize"))
        _ = qjs.set_property(h.js.ctx, obj, "w", qjs.new_i32(i32(h.width)))
        _ = qjs.set_property(h.js.ctx, obj, "h", qjs.new_i32(i32(h.height)))

    case term.Mouse:
        _ = qjs.set_property(h.js.ctx, obj, "type", qjs.new_string(h.js.ctx, "mouse"))
        _ = qjs.set_property(h.js.ctx, obj, "x", qjs.new_i32(i32(e.x)))
        _ = qjs.set_property(h.js.ctx, obj, "y", qjs.new_i32(i32(e.y)))
        _ = qjs.set_property(h.js.ctx, obj, "event", qjs.new_string(h.js.ctx, term.mouse_event_names[e.event]))
        _ = qjs.set_property(h.js.ctx, obj, "button", qjs.new_string(h.js.ctx, term.mouse_button_names[e.button]))
        _ = qjs.set_property(h.js.ctx, obj, "mods", qjs.new_i32(i32(transmute(u8)e.mods)))

    case term.Input_Closed:
        unreachable()
    }

    return obj
}

// A codepoint as a JS string; an unreported codepoint (0) becomes the empty string.
host_rune_value :: proc(h: ^Host, cp: rune) -> qjs.Value {
    if cp == 0 do return qjs.new_string(h.js.ctx, "")

    enc, n := utf8.encode_rune(cp)

    return qjs.new_string(h.js.ctx, string(enc[:n]))
}

host_resize_buffer :: proc(h: ^Host, w, ht: u16) {
    if !h.has_buf || w == 0 || ht == 0 do return
    if h.buf.area.width == w && h.buf.area.height == ht do return

    if ui.buffer_resize(&h.buf, w, ht) != .None do return

    h.width = w
    h.height = ht
    h.dirty = false
    h.in_frame = false

    // Update cached size object and term.width/height if retained.
    if !qjs.is_undefined(h.size_obj) {
        _ = qjs.set_property(h.js.ctx, h.size_obj, "w", qjs.new_i32(i32(w)))
        _ = qjs.set_property(h.js.ctx, h.size_obj, "h", qjs.new_i32(i32(ht)))
    }
    if !qjs.is_undefined(h.term_obj) {
        _ = qjs.set_property(h.js.ctx, h.term_obj, "width", qjs.new_i32(i32(w)))
        _ = qjs.set_property(h.js.ctx, h.term_obj, "height", qjs.new_i32(i32(ht)))
    }
}

// Ensure a frame is open (current grid ready for draw). After endFrame the
// current grid is empty; beginFrame is required for a full immediate-mode pass.
host_begin_frame :: proc(h: ^Host) {
    if !h.has_buf do return
    ui.buffer_begin_frame(&h.buf)
    h.in_frame = true
    h.dirty = true
}

// Diff current vs previous; emit only changed cells; swap double buffer.
host_end_frame :: proc(h: ^Host) {
    if !h.has_buf || !h.dirty {
        h.in_frame = false
        return
    }

    if ui.flush_diff(&h.buf, h.out, h.sync) == .None {
        h.dirty = false
        h.in_frame = false
    }
    // On failure dirty stays true so the next endFrame retries (force_redraw).
}

host_ensure_frame :: proc(h: ^Host) {
    if !h.in_frame do host_begin_frame(h)
}

host_start :: proc(h: ^Host) {
    obj := qjs.new_object(h.js.ctx)
    _ = qjs.set_property(h.js.ctx, obj, "type", qjs.new_string(h.js.ctx, "start"))
    defer qjs.free_value(h.js.ctx, obj)

    host_dispatch(h, obj)
}

// Repaint after an out-of-band open-session change (a folded broadcast or installed resync). Like
// a tick, any dispatched event redraws. Never called from a native call, to avoid re-entering a draw.
host_dispatch_session :: proc(h: ^Host) {
    if h.done || h.js.ctx == nil do return

    obj := qjs.new_object(h.js.ctx)
    _ = qjs.set_property(h.js.ctx, obj, "type", qjs.new_string(h.js.ctx, "session"))
    defer qjs.free_value(h.js.ctx, obj)

    host_dispatch(h, obj)
}

// --- yuke:term module ---

host_set_needs_tick :: proc(h: ^Host, enabled: bool, period: time.Duration) {
    assert(h != nil, "host_set_needs_tick needs a host")

    // After quit/input_closed: ignore re-arm from paint-after-quit; always clear.
    if h.done {
        h.needs_tick = false
        host_cancel_tick(h)
        return
    }

    p := host_clamp_tick_period(period if period > 0 else TICK_MS_DEFAULT)
    period_changed := h.tick_period != p
    h.tick_period = p
    h.needs_tick = enabled

    if enabled {
        // Re-arm if newly enabled or period changed so the next wake matches policy.
        if h.tick_op != nil && period_changed do host_cancel_tick(h)
        if h.tick_op == nil do host_arm_tick(h)
    } else {
        host_cancel_tick(h)
    }
}

host_arm_tick :: proc(h: ^Host) {
    assert(h != nil, "host_arm_tick needs a host")
    assert(h.tick_op == nil, "host_arm_tick with in-flight op")
    assert(h.drive != nil && h.drive.loop != nil, "host_arm_tick needs drive loop")

    period := h.tick_period if h.tick_period > 0 else TICK_MS_DEFAULT
    h.tick_op = nbio.timeout_poly(period, h, host_on_tick, h.drive.loop)
}

host_cancel_tick :: proc(h: ^Host) {
    assert(h != nil, "host_cancel_tick needs a host")

    if h.tick_op != nil {
        nbio.remove(h.tick_op)
        h.tick_op = nil
    }
}

// nbio deadline: dispatch {type:"tick"} then re-arm while needs_tick.
host_on_tick :: proc(_: ^nbio.Operation, h: ^Host) {
    assert(h != nil, "host_on_tick needs a host")
    h.tick_op = nil

    if h.done || h.js.ctx == nil || !h.needs_tick do return

    obj := qjs.new_object(h.js.ctx)
    _ = qjs.set_property(h.js.ctx, obj, "type", qjs.new_string(h.js.ctx, "tick"))
    defer qjs.free_value(h.js.ctx, obj)

    host_dispatch(h, obj)

    // Script may have cleared needs_tick during paint (left home / no runners).
    if h.needs_tick && !h.done && h.tick_op == nil do host_arm_tick(h)
}
