package tui

/*
Client script tier: the `yuke:term` module and the glue that binds this process's Host to
`src/js`. `yuke:term` paints into this terminal, so it lives here rather than beside the
shared modules; the host resolves it through the same registry as `yuke:fs`.
*/

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:time"

import qjs "libs:bindings/quickjs"
import "src:js"
import "src:term"
import "src:term/ui"

// A module's `exports` is borrowed for the host's life, so it outlives `host_init`.
@(rodata)
TERM_EXPORTS := []string{"term"}

// `yuke:term` for the host's module list. Client-only: it paints into this process's
// terminal, which is why it lives here rather than beside the shared modules.
term_module :: proc() -> js.Module {
    return {name = "yuke:term", init = host_term_module_init, exports = TERM_EXPORTS}
}

// Resolves specifiers the native modules do not cover: the baked core and default UI (static, so
// unowned), and any file under the config root (its `yuke.js` and plugins, read into the host
// allocator, so owned — the loader frees it after compiling). A specifier outside the root, or
// with no config root at all, is left unresolved so the loader throws.
host_resolve :: proc(user: rawptr, name: string, allocator: mem.Allocator) -> (string, bool, bool) {
    switch name {
    case "yuke:core":
        return CORE_JS, false, true

    case "yuke:ui":
        return UI_JS, false, true

    case "yuke:defaults":
        return DEFAULTS_JS, false, true

    case "yuke:client":
        return CLIENT_JS, false, true
    }

    h := (^Host)(user)
    if h == nil || h.config_root == "" {
        return "", false, false
    }

    // The default module normalize resolves a relative import against the importer's absolute
    // path, so a file specifier arrives already absolute; contain it before touching disk.
    if !js.path_contained(h.config_root, name) {
        return "", false, false
    }

    data, read_err := os.read_entire_file(name, allocator)
    if read_err != nil {
        return "", false, false
    }

    return string(data), true, true
}

// Bring up the baked UI, then the user's `yuke.js` layered on top, then latch `onEvent`. Reading
// it last honors a user file that installs its own router; a broken user file is reported but
// does not fail the client — the baked core still runs. `eval_module` reports a top-level throw
// rather than swallowing it, so a rejection is not misread as the missing `onEvent` below.
host_eval_app :: proc(h: ^Host) -> bool {
    if !js.eval_module(&h.js, "yuke:app", APP_JS, h.allocator) {
        return false
    }

    host_eval_user(h)

    global := qjs.global_object(h.js.ctx)
    defer qjs.free_value(h.js.ctx, global)
    on_ev := qjs.get_property(h.js.ctx, global, "onEvent")
    if qjs.is_exception(on_ev) {
        host_report(h, "yuke:app", "onEvent could not be read")
        return false
    }
    if qjs.is_undefined(on_ev) {
        qjs.free_value(h.js.ctx, on_ev)
        host_set_last_err(h, "app.js did not set globalThis.onEvent")
        return false
    }
    h.on_event = on_ev

    return true
}

// Evaluate `<config_root>/yuke.js` when it exists, named by its absolute path so relative plugin
// imports resolve under the config root. Its failure is reported, not fatal: the baked UI stays
// up rather than a config typo bringing the client down.
host_eval_user :: proc(h: ^Host) {
    if h.config_root == "" {
        return
    }

    path, join_err := filepath.join({h.config_root, USER_ENTRY}, h.allocator)
    if join_err != nil {
        return
    }

    defer delete(path, h.allocator)

    if !os.exists(path) {
        return
    }

    source, read_err := os.read_entire_file(path, h.allocator)
    if read_err != nil {
        host_report(h, USER_ENTRY, "could not be read")
        return
    }

    defer delete(source, h.allocator)

    _ = js.eval_module(&h.js, path, string(source), h.allocator)
}

// A script fault ends the session here. `last_err` is the main loop's exit condition, and
// the message is printed only after the alternate screen comes down — logging while it is
// up would corrupt the display, which is why the shared host reports rather than logs.
host_report :: proc(user: rawptr, source: string, text: string) {
    h := (^Host)(user)
    host_set_last_err(h, fmt.tprintf("%s: %s", source, text))
}

host_term_module_init :: proc "c" (ctx: ^qjs.Context, m: ^qjs.Module_Def) -> c.int {
    context = runtime.default_context()
    h := host_from_ctx(ctx)

    term_obj := qjs.new_object(ctx)
    _ = qjs.set_property(ctx, term_obj, "beginFrame", qjs.new_function(ctx, host_term_begin_frame, "beginFrame", 0))
    _ = qjs.set_property(ctx, term_obj, "endFrame", qjs.new_function(ctx, host_term_end_frame, "endFrame", 0))
    _ = qjs.set_property(ctx, term_obj, "fill", qjs.new_function(ctx, host_term_fill, "fill", 4))
    _ = qjs.set_property(ctx, term_obj, "text", qjs.new_function(ctx, host_term_text, "text", 3))
    _ = qjs.set_property(ctx, term_obj, "measure", qjs.new_function(ctx, host_term_measure, "measure", 1))
    _ = qjs.set_property(ctx, term_obj, "graphemes", qjs.new_function(ctx, host_term_graphemes, "graphemes", 1))
    _ = qjs.set_property(ctx, term_obj, "cursor", qjs.new_function(ctx, host_term_cursor, "cursor", 3))
    _ = qjs.set_property(ctx, term_obj, "size", qjs.new_function(ctx, host_term_size, "size", 0))
    _ = qjs.set_property(
        ctx,
        term_obj,
        "setNeedsTick",
        qjs.new_function(ctx, host_term_set_needs_tick, "setNeedsTick", 2),
    )
    _ = qjs.set_property(ctx, term_obj, "quit", qjs.new_function(ctx, host_term_quit, "quit", 0))
    _ = qjs.set_property(ctx, term_obj, "keyMatches", qjs.new_function(ctx, host_term_key_matches, "keyMatches", 3))

    w: i32 = 80
    ht: i32 = 24
    if h != nil {
        w = i32(h.width)
        ht = i32(h.height)
        // Keep a host ref for width/height updates; export consumes its own ref.
        h.term_obj = qjs.dup_value(ctx, term_obj)
    }
    _ = qjs.set_property(ctx, term_obj, "width", qjs.new_i32(w))
    _ = qjs.set_property(ctx, term_obj, "height", qjs.new_i32(ht))

    if !qjs.set_module_export(ctx, m, "term", term_obj) {
        if h != nil && !qjs.is_undefined(h.term_obj) {
            qjs.free_value(ctx, h.term_obj)
            h.term_obj = qjs.undefined()
        }
        return -1
    }

    return 0
}

host_from_ctx :: proc(ctx: ^qjs.Context) -> ^Host {
    return (^Host)(js.user_of(ctx))
}

host_term_begin_frame :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this
    _ = argc
    _ = argv

    h := host_from_ctx(ctx)
    if h == nil || !h.has_buf {
        return qjs.throw_type_error(ctx, "term.beginFrame: no host")
    }
    host_begin_frame(h)
    return qjs.undefined()
}

host_term_end_frame :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this
    _ = argc
    _ = argv

    h := host_from_ctx(ctx)
    if h == nil || !h.has_buf {
        return qjs.throw_type_error(ctx, "term.endFrame: no host")
    }
    host_end_frame(h)
    return qjs.undefined()
}

host_term_size :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this
    _ = argc
    _ = argv

    h := host_from_ctx(ctx)
    if h == nil {
        return qjs.throw_type_error(ctx, "term.size: no host")
    }
    // Return retained object (w/h already updated on resize).
    return qjs.dup_value(ctx, h.size_obj)
}

host_term_fill :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil || !h.has_buf {
        return qjs.throw_type_error(ctx, "term.fill: no host")
    }
    if argc < 4 {
        return qjs.throw_type_error(ctx, "term.fill(x, y, w, h, style?)")
    }

    x, xok := qjs.to_i32(ctx, argv[0])
    y, yok := qjs.to_i32(ctx, argv[1])
    w, wok := qjs.to_i32(ctx, argv[2])
    ht, hok := qjs.to_i32(ctx, argv[3])
    if !xok || !yok || !wok || !hok {
        return qjs.exception()
    }
    if x < 0 || y < 0 || w <= 0 || ht <= 0 {
        return qjs.undefined()
    }

    style := host_parse_style(ctx, argc, argv, 4)
    host_ensure_frame(h)
    _ = ui.buffer_fill(&h.buf, ui.Rect{x = u16(x), y = u16(y), width = u16(w), height = u16(ht)}, " ", style)
    h.dirty = true
    return qjs.undefined()
}

host_term_text :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil || !h.has_buf {
        return qjs.throw_type_error(ctx, "term.text: no host")
    }
    if argc < 3 {
        return qjs.throw_type_error(ctx, "term.text(x, y, s, style?)")
    }

    x, xok := qjs.to_i32(ctx, argv[0])
    y, yok := qjs.to_i32(ctx, argv[1])
    if !xok || !yok {
        return qjs.exception()
    }

    s, sok := qjs.to_string(ctx, argv[2])
    if !sok {
        return qjs.exception()
    }
    defer qjs.free_string(ctx, s)

    if x < 0 || y < 0 {
        return qjs.undefined()
    }

    style := host_parse_style(ctx, argc, argv, 3)
    host_ensure_frame(h)
    _, _ = ui.buffer_put_str(&h.buf, u16(x), u16(y), s, style)
    h.dirty = true
    return qjs.undefined()
}

// Display width of `s` in terminal cells. Pure — no buffer, usable before the first frame.
host_term_measure :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    if argc < 1 {
        return qjs.throw_type_error(ctx, "term.measure(s)")
    }

    s, sok := qjs.to_string(ctx, argv[0])
    if !sok {
        return qjs.exception()
    }
    defer qjs.free_string(ctx, s)

    return qjs.new_i32(i32(ui.str_width(s)))
}

// Grapheme clusters of `s` as a flat Int32Array of [i, n, w] triples: UTF-16 offset, UTF-16
// length (JS slices s.slice(i, i+n)), and cell width. Contiguous over the whole string.
host_term_graphemes :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    if argc < 1 {
        return qjs.throw_type_error(ctx, "term.graphemes(s)")
    }

    s, sok := qjs.to_string(ctx, argv[0])
    if !sok {
        return qjs.exception()
    }
    defer qjs.free_string(ctx, s)

    triples := make([dynamic]i32, 0, 48)
    defer delete(triples)

    u16_off: i32 = 0
    it := ui.clusters(s)
    for {
        cl, ok := ui.iter_next(&it)
        if !ok {
            break
        }

        n := i32(ui.str_utf16_len(ui.cluster_bytes(cl, s)))
        append(&triples, u16_off, n, i32(ui.cluster_width(cl, s)))
        u16_off += n
    }

    return qjs.new_int32_array(ctx, triples[:])
}

host_term_cursor :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil || !h.has_buf {
        return qjs.throw_type_error(ctx, "term.cursor: no host")
    }
    if argc < 3 {
        return qjs.throw_type_error(ctx, "term.cursor(x, y, visible)")
    }

    x, xok := qjs.to_i32(ctx, argv[0])
    y, yok := qjs.to_i32(ctx, argv[1])
    vis, vok := qjs.to_bool(ctx, argv[2])
    if !xok || !yok || !vok {
        return qjs.exception()
    }

    // Same clipping rule as fill/text: negative cell coords are a no-op.
    if x < 0 || y < 0 {
        return qjs.undefined()
    }

    host_ensure_frame(h)
    ui.buffer_set_cursor(&h.buf, u16(x), u16(y), vis)
    h.dirty = true
    return qjs.undefined()
}

host_term_quit :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this
    _ = argc
    _ = argv

    h := host_from_ctx(ctx)
    if h != nil {
        h.needs_tick = false
        host_cancel_tick(h)
        h.done = true
    }
    return qjs.undefined()
}

// term.keyMatches(ev, cp, mods?): whether a key event is the keystroke `cp` + `mods`.
// Decided by `term.key_matches` over the event's own fields, so a shortcut written once
// holds on both Kitty and legacy terminals.
host_term_key_matches :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    if argc < 2 || !qjs.is_object(argv[0]) || !qjs.is_string(argv[1]) {
        return qjs.throw_type_error(ctx, "term.keyMatches(ev, cp, mods?)")
    }

    cp, cpok := host_first_rune(ctx, argv[1])
    if !cpok {
        return qjs.exception()
    }

    mods: term.Modifiers
    if argc >= 3 {
        m, mok := qjs.to_i32(ctx, argv[2])
        if !mok {
            return qjs.exception()
        }

        mods = host_mods_from_bits(m)
    }

    key, kok := host_key_from_value(ctx, argv[0])
    if !kok {
        return qjs.exception()
    }

    return qjs.new_bool(term.key_matches(&key, cp, mods))
}

// Rebuild the fields `key_matches` reads from a marshalled key event. A missing field is
// absent, never coerced: `to_string` renders `undefined` as "undefined", which would match
// a real keystroke.
host_key_from_value :: proc(ctx: ^qjs.Context, v: qjs.Value) -> (key: term.Key, ok: bool) {
    key.char = host_value_rune(ctx, v, "char") or_return
    key.shifted = host_value_rune(ctx, v, "shifted") or_return

    text_val := qjs.get_property(ctx, v, "text")
    defer qjs.free_value(ctx, text_val)
    if qjs.is_exception(text_val) {
        return {}, false
    }

    if qjs.is_string(text_val) {
        text, tok := qjs.to_string(ctx, text_val)
        if !tok {
            return {}, false
        }
        defer qjs.free_string(ctx, text)

        for r in text {
            term.key_text_append(&key, r)
        }
    }

    mods_val := qjs.get_property(ctx, v, "mods")
    defer qjs.free_value(ctx, mods_val)
    if qjs.is_exception(mods_val) {
        return {}, false
    }

    if !qjs.is_undefined(mods_val) {
        m, mok := qjs.to_i32(ctx, mods_val)
        if !mok {
            return {}, false
        }

        key.mods = host_mods_from_bits(m)
    }

    return key, true
}

// A JS `mods` bit integer as a modifier set, dropping bits that name no modifier — a set
// carrying them would compare equal to nothing.
host_mods_from_bits :: proc(v: i32) -> term.Modifiers {
    all := ~term.Modifiers{}

    return transmute(term.Modifiers)(u8(v) & transmute(u8)all)
}

// Property `name` of `v` as its first codepoint, 0 unless it is a non-empty string. `ok`
// is false only when the read threw, which leaves an exception pending for the caller.
host_value_rune :: proc(ctx: ^qjs.Context, v: qjs.Value, name: string) -> (rune, bool) {
    prop := qjs.get_property(ctx, v, name)
    defer qjs.free_value(ctx, prop)

    if qjs.is_exception(prop) {
        return 0, false
    }

    if !qjs.is_string(prop) {
        return 0, true
    }

    s, ok := qjs.to_string(ctx, prop)
    if !ok {
        return 0, false
    }
    defer qjs.free_string(ctx, s)

    return first_rune(s), true
}

// First codepoint of a JS string argument; an empty string matches nothing.
host_first_rune :: proc(ctx: ^qjs.Context, v: qjs.Value) -> (rune, bool) {
    s, ok := qjs.to_string(ctx, v)
    if !ok {
        return 0, false
    }
    defer qjs.free_string(ctx, s)

    return first_rune(s), true
}

// First codepoint of `s`, or 0 when empty. Deliberately 0 (an unreported codepoint), not
// `utf8.RUNE_ERROR`, so an empty string matches nothing rather than a replacement char.
first_rune :: proc(s: string) -> rune {
    for r in s {
        return r
    }

    return 0
}

// term.setNeedsTick(enabled, periodMs?): arm/cancel demand-driven UI ticks.
// periodMs optional (default 450); clamped to [50, 2000]. Idle when false.
host_term_set_needs_tick :: proc "c" (
    ctx: ^qjs.Context,
    this: qjs.Value,
    argc: c.int,
    argv: [^]qjs.Value,
) -> qjs.Value {
    context = runtime.default_context()
    _ = this

    h := host_from_ctx(ctx)
    if h == nil {
        return qjs.throw_type_error(ctx, "term.setNeedsTick: no host")
    }
    if argc < 1 {
        return qjs.throw_type_error(ctx, "term.setNeedsTick(enabled, periodMs?)")
    }

    enabled, ok := qjs.to_bool(ctx, argv[0])
    if !ok {
        return qjs.exception()
    }

    period := h.tick_period
    if period <= 0 {
        period = TICK_MS_DEFAULT
    }
    if argc >= 2 && !qjs.is_undefined(argv[1]) && !qjs.is_null(argv[1]) {
        ms, mok := qjs.to_i32(ctx, argv[1])
        if !mok {
            return qjs.exception()
        }
        period = host_clamp_tick_period(time.Duration(ms) * time.Millisecond)
    }

    host_set_needs_tick(h, enabled, period)
    return qjs.undefined()
}

host_clamp_tick_period :: proc(d: time.Duration) -> time.Duration {
    if d < TICK_MS_MIN {
        return TICK_MS_MIN
    }
    if d > TICK_MS_MAX {
        return TICK_MS_MAX
    }
    return d
}

// style optional at argv[style_idx]: { fg?, bg?, bold?, dim?, italic?, underline? }
// fg/bg: ANSI name string, or integer 0..255 for a 256-color palette index.
host_parse_style :: proc(ctx: ^qjs.Context, argc: c.int, argv: [^]qjs.Value, style_idx: int) -> ui.Style {
    style := ui.Style {
        fg = ui.Ansi_Color.White,
    }
    if int(argc) <= style_idx {
        return style
    }
    st := argv[style_idx]
    if !qjs.is_object(st) {
        return style
    }

    if fg := qjs.get_property(ctx, st, "fg"); !qjs.is_undefined(fg) {
        defer qjs.free_value(ctx, fg)
        if c, ok := host_parse_color(ctx, fg); ok {
            style.fg = c
        }
    }
    if bg := qjs.get_property(ctx, st, "bg"); !qjs.is_undefined(bg) {
        defer qjs.free_value(ctx, bg)
        if c, ok := host_parse_color(ctx, bg); ok {
            style.bg = c
        }
    }
    for f in STYLE_FLAGS {
        b := qjs.get_property(ctx, st, f.prop)
        defer qjs.free_value(ctx, b)

        if v, ok := qjs.to_bool(ctx, b); ok && v {
            style.mods += {f.mod}
        }
    }

    return style
}

// Boolean style properties: the JS property name and the modifier each one sets.
@(rodata)
STYLE_FLAGS := [?]struct {
    prop: string,
    mod:  ui.Modifier,
}{{"bold", .Bold}, {"dim", .Dim}, {"italic", .Italic}, {"underline", .Underlined}}

// ANSI name string or integer 0..255 → ui.Color.
host_parse_color :: proc(ctx: ^qjs.Context, v: qjs.Value) -> (ui.Color, bool) {
    if qjs.is_number(v) {
        n, ok := qjs.to_i32(ctx, v)
        if !ok || n < 0 || n > 255 {
            return nil, false
        }

        return ui.Indexed(u8(n)), true
    }

    if s, ok := qjs.to_string(ctx, v); ok {
        defer qjs.free_string(ctx, s)
        if c, cok := ansi_color_from_name(s); cok {
            return c, true
        }
    }

    return nil, false
}

ansi_color_from_name :: proc(name: string) -> (ui.Ansi_Color, bool) {
    switch name {
    case "reset":
        return .Reset, true
    case "black":
        return .Black, true
    case "red":
        return .Red, true
    case "green":
        return .Green, true
    case "yellow":
        return .Yellow, true
    case "blue":
        return .Blue, true
    case "magenta":
        return .Magenta, true
    case "cyan":
        return .Cyan, true
    case "gray", "grey":
        return .Gray, true
    case "dark_gray", "dark_grey":
        return .Dark_Gray, true
    case "light_red":
        return .Light_Red, true
    case "light_green":
        return .Light_Green, true
    case "light_yellow":
        return .Light_Yellow, true
    case "light_blue":
        return .Light_Blue, true
    case "light_magenta":
        return .Light_Magenta, true
    case "light_cyan":
        return .Light_Cyan, true
    case "white":
        return .White, true
    }
    return .White, false
}
