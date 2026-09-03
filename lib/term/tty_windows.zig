const std = @import("std");
const windows = std.os.windows;
const xvaxis = @import("xvaxis/main.zig");
const zio = @import("zio");

const Event = xvaxis.Event;
const Key = xvaxis.Key;
const Mouse = xvaxis.Mouse;
const Parser = xvaxis.Parser;

pub const Winsize = xvaxis.Winsize;

const generic_read: windows.DWORD = 0x80000000;
const generic_write: windows.DWORD = 0x40000000;
const file_share_read: windows.DWORD = 0x00000001;
const file_share_write: windows.DWORD = 0x00000002;
const open_existing: windows.DWORD = 3;
const utf8_codepage: windows.UINT = 65001;

const conin_name = std.unicode.utf8ToUtf16LeStringLiteral("CONIN$");
const conout_name = std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$");

/// Windows reports resize through a console input record.
pub const WinsizeWatch = struct {
    pub fn init() !WinsizeWatch {
        return .{};
    }

    pub fn deinit(self: *WinsizeWatch) void {
        self.* = undefined;
    }

    pub fn wait(_: *WinsizeWatch, _: *const Tty) error{ResizeInBand}!Winsize {
        return error.ResizeInBand;
    }
};

/// A raw-mode handle for the controlling console. `nextEvent` runs in a zio task.
pub const Tty = struct {
    io: std.Io,
    in: std.Io.File,
    out: std.Io.File,
    initial_codepage: windows.UINT,
    initial_input_mode: CONSOLE_MODE_INPUT,
    initial_output_mode: CONSOLE_MODE_OUTPUT,
    buf: [4]u8 = undefined,
    last_mouse_button_press: u16 = 0,

    pub const input_raw_mode: CONSOLE_MODE_INPUT = .{
        .WINDOW_INPUT = 1,
        .MOUSE_INPUT = 1,
        .EXTENDED_FLAGS = 1,
    };

    pub const output_raw_mode: CONSOLE_MODE_OUTPUT = .{
        .PROCESSED_OUTPUT = 1,
        .VIRTUAL_TERMINAL_PROCESSING = 1,
        .DISABLE_NEWLINE_AUTO_RETURN = 1,
        .ENABLE_LVB_GRID_WORLDWIDE = 1,
    };

    /// Open `CONIN$` and `CONOUT$`, then enter raw console mode.
    pub fn open(io: std.Io) !Tty {
        const stdin = try openConsole(conin_name, generic_read | generic_write, file_share_read);
        errdefer windows.CloseHandle(stdin);
        const stdout = try openConsole(
            conout_name,
            generic_read | generic_write,
            file_share_read | file_share_write,
        );
        errdefer windows.CloseHandle(stdout);

        const initial_codepage = GetConsoleOutputCP();
        const initial_input_mode = try getConsoleMode(CONSOLE_MODE_INPUT, stdin);
        const initial_output_mode = try getConsoleMode(CONSOLE_MODE_OUTPUT, stdout);

        try setConsoleMode(stdin, input_raw_mode);
        errdefer setConsoleMode(stdin, initial_input_mode) catch {};
        try setConsoleMode(stdout, output_raw_mode);
        errdefer setConsoleMode(stdout, initial_output_mode) catch {};
        if (SetConsoleOutputCP(utf8_codepage) == .FALSE)
            return windows.unexpectedError(windows.GetLastError());

        return .{
            .io = io,
            .in = .{ .handle = stdin, .flags = .{ .nonblocking = false } },
            .out = .{ .handle = stdout, .flags = .{ .nonblocking = false } },
            .initial_codepage = initial_codepage,
            .initial_input_mode = initial_input_mode,
            .initial_output_mode = initial_output_mode,
        };
    }

    /// Close `CONIN$` to wake a blocked read.
    pub fn shutdownInput(self: *Tty) void {
        if (self.in.handle == windows.INVALID_HANDLE_VALUE) return;
        setConsoleMode(self.in.handle, self.initial_input_mode) catch {};
        windows.CloseHandle(self.in.handle);
        self.in.handle = windows.INVALID_HANDLE_VALUE;
    }

    /// Restore console modes and close both handles.
    pub fn deinit(self: *Tty) void {
        self.shutdownInput();
        _ = SetConsoleOutputCP(self.initial_codepage);
        setConsoleMode(self.out.handle, self.initial_output_mode) catch {};
        windows.CloseHandle(self.out.handle);
        self.* = undefined;
    }

    /// Build a buffered console writer. The caller owns the buffer.
    pub fn writerStreaming(self: *Tty, buffer: []u8) std.Io.File.Writer {
        return self.out.writerStreaming(self.io, buffer);
    }

    /// Read the visible console size.
    pub fn getWinsize(self: *const Tty) !Winsize {
        return winsizeFromHandle(self.out.handle);
    }

    /// Read the next console event. The reactor waits when no input exists.
    pub fn nextEvent(self: *Tty, parser: *Parser, paste_allocator: ?std.mem.Allocator) !Event {
        var state: EventState = .{};
        while (true) {
            const record = try self.readRecord();
            if (try self.eventFromRecord(&record, &state, parser, paste_allocator)) |ev|
                return ev;
        }
    }

    fn readRecord(self: *Tty) !INPUT_RECORD {
        var pending: windows.DWORD = 0;
        if (GetNumberOfConsoleInputEvents(self.in.handle, &pending) == .FALSE)
            return windows.unexpectedError(windows.GetLastError());
        if (pending > 0)
            return readRecordBlocking(self.in.handle);

        var join = try zio.spawnBlocking(readRecordBlocking, .{self.in.handle});
        return join.join();
    }

    pub const CONSOLE_MODE_INPUT = packed struct(u32) {
        PROCESSED_INPUT: u1 = 0,
        LINE_INPUT: u1 = 0,
        ECHO_INPUT: u1 = 0,
        WINDOW_INPUT: u1 = 0,
        MOUSE_INPUT: u1 = 0,
        INSERT_MODE: u1 = 0,
        QUICK_EDIT_MODE: u1 = 0,
        EXTENDED_FLAGS: u1 = 0,
        AUTO_POSITION: u1 = 0,
        VIRTUAL_TERMINAL_INPUT: u1 = 0,
        _: u22 = 0,
    };

    pub const CONSOLE_MODE_OUTPUT = packed struct(u32) {
        PROCESSED_OUTPUT: u1 = 0,
        WRAP_AT_EOL_OUTPUT: u1 = 0,
        VIRTUAL_TERMINAL_PROCESSING: u1 = 0,
        DISABLE_NEWLINE_AUTO_RETURN: u1 = 0,
        ENABLE_LVB_GRID_WORLDWIDE: u1 = 0,
        _: u27 = 0,
    };

    pub const EventState = struct {
        ansi_buf: [128]u8 = undefined,
        ansi_idx: usize = 0,
        utf16_buf: [2]u16 = undefined,
        utf16_half: bool = false,
    };

    pub const SMALL_RECT = extern struct {
        Left: windows.SHORT,
        Top: windows.SHORT,
        Right: windows.SHORT,
        Bottom: windows.SHORT,
    };

    pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        dwSize: windows.COORD,
        dwCursorPosition: windows.COORD,
        wAttributes: windows.WORD,
        srWindow: SMALL_RECT,
        dwMaximumWindowSize: windows.COORD,
    };

    /// Map a Win32 input record to an xvaxis event. Return null for unsupported records.
    pub fn eventFromRecord(
        self: *Tty,
        record: *const INPUT_RECORD,
        state: *EventState,
        parser: *Parser,
        paste_allocator: ?std.mem.Allocator,
    ) !?Event {
        switch (record.EventType) {
            0x0001 => {
                const event = record.Event.KeyEvent;

                if (state.utf16_half) half: {
                    state.utf16_half = false;
                    state.utf16_buf[1] = event.uChar.UnicodeChar;
                    const codepoint: u21 = std.unicode.utf16DecodeSurrogatePair(&state.utf16_buf) catch break :half;
                    const n = std.unicode.utf8Encode(codepoint, &self.buf) catch return null;

                    const key: Key = .{
                        .codepoint = codepoint,
                        .base_layout_codepoint = codepoint,
                        .mods = translateMods(event.dwControlKeyState),
                        .text = self.buf[0..n],
                    };

                    switch (event.bKeyDown) {
                        .FALSE => return .{ .key_release = key },
                        else => return .{ .key_press = key },
                    }
                }

                const base_layout: u16 = switch (event.wVirtualKeyCode) {
                    0x00 => blk: {
                        if (state.ansi_idx == 0 and event.uChar.AsciiChar != 27)
                            break :blk event.uChar.UnicodeChar;
                        if (state.ansi_idx == state.ansi_buf.len) {
                            state.ansi_idx = 0;
                            return null;
                        }
                        state.ansi_buf[state.ansi_idx] = event.uChar.AsciiChar;
                        state.ansi_idx += 1;
                        if (state.ansi_idx <= 2) return null;
                        const result = try parser.parse(state.ansi_buf[0..state.ansi_idx], paste_allocator);
                        return if (result.n == 0) null else evt: {
                            state.ansi_idx = 0;
                            break :evt result.event;
                        };
                    },
                    0x08 => Key.backspace,
                    0x09 => Key.tab,
                    0x0D => Key.enter,
                    0x13 => Key.pause,
                    0x14 => Key.caps_lock,
                    0x1B => Key.escape,
                    0x20 => Key.space,
                    0x21 => Key.page_up,
                    0x22 => Key.page_down,
                    0x23 => Key.end,
                    0x24 => Key.home,
                    0x25 => Key.left,
                    0x26 => Key.up,
                    0x27 => Key.right,
                    0x28 => Key.down,
                    0x2c => Key.print_screen,
                    0x2d => Key.insert,
                    0x2e => Key.delete,
                    0x30...0x39 => |k| k,
                    0x41...0x5a => |k| k + 0x20,
                    0x5b => Key.left_meta,
                    0x5c => Key.right_meta,
                    0x60 => Key.kp_0,
                    0x61 => Key.kp_1,
                    0x62 => Key.kp_2,
                    0x63 => Key.kp_3,
                    0x64 => Key.kp_4,
                    0x65 => Key.kp_5,
                    0x66 => Key.kp_6,
                    0x67 => Key.kp_7,
                    0x68 => Key.kp_8,
                    0x69 => Key.kp_9,
                    0x6a => Key.kp_multiply,
                    0x6b => Key.kp_add,
                    0x6c => Key.kp_separator,
                    0x6d => Key.kp_subtract,
                    0x6e => Key.kp_decimal,
                    0x6f => Key.kp_divide,
                    0x70 => Key.f1,
                    0x71 => Key.f2,
                    0x72 => Key.f3,
                    0x73 => Key.f4,
                    0x74 => Key.f5,
                    0x75 => Key.f6,
                    0x76 => Key.f7,
                    0x77 => Key.f8,
                    0x78 => Key.f9,
                    0x79 => Key.f10,
                    0x7a => Key.f11,
                    0x7b => Key.f12,
                    0x7c => Key.f13,
                    0x7d => Key.f14,
                    0x7e => Key.f15,
                    0x7f => Key.f16,
                    0x80 => Key.f17,
                    0x81 => Key.f18,
                    0x82 => Key.f19,
                    0x83 => Key.f20,
                    0x84 => Key.f21,
                    0x85 => Key.f22,
                    0x86 => Key.f23,
                    0x87 => Key.f24,
                    0x90 => Key.num_lock,
                    0x91 => Key.scroll_lock,
                    0xa0 => Key.left_shift,
                    0x10 => Key.left_shift,
                    0xa1 => Key.right_shift,
                    0xa2 => Key.left_control,
                    0x11 => Key.left_control,
                    0xa3 => Key.right_control,
                    0xa4 => Key.left_alt,
                    0x12 => Key.left_alt,
                    0xa5 => Key.right_alt,
                    0xad => Key.mute_volume,
                    0xae => Key.lower_volume,
                    0xaf => Key.raise_volume,
                    0xb0 => Key.media_track_next,
                    0xb1 => Key.media_track_previous,
                    0xb2 => Key.media_stop,
                    0xb3 => Key.media_play_pause,
                    0xba => ';',
                    0xbb => '+',
                    0xbc => ',',
                    0xbd => '-',
                    0xbe => '.',
                    0xbf => '/',
                    0xc0 => '`',
                    0xdb => '[',
                    0xdc => '\\',
                    0xdf => '\\',
                    0xe2 => '\\',
                    0xdd => ']',
                    0xde => '\'',
                    else => {
                        std.log.scoped(.term).warn("unknown wVirtualKeyCode: 0x{x}", .{event.wVirtualKeyCode});
                        return null;
                    },
                };

                if (std.unicode.utf16IsHighSurrogate(base_layout)) {
                    state.utf16_buf[0] = base_layout;
                    state.utf16_half = true;
                    return null;
                }
                if (std.unicode.utf16IsLowSurrogate(base_layout)) {
                    return null;
                }

                var codepoint: u21 = base_layout;
                var text: ?[]const u8 = null;
                switch (event.uChar.UnicodeChar) {
                    0x00...0x1F => {},
                    else => |cp| {
                        codepoint = cp;
                        const n = try std.unicode.utf8Encode(codepoint, &self.buf);
                        text = self.buf[0..n];
                    },
                }

                const key: Key = .{
                    .codepoint = codepoint,
                    .base_layout_codepoint = base_layout,
                    .mods = translateMods(event.dwControlKeyState),
                    .text = text,
                };

                switch (event.bKeyDown) {
                    .FALSE => return .{ .key_release = key },
                    else => return .{ .key_press = key },
                }
            },
            0x0002 => {
                const event = record.Event.MouseEvent;

                const mouse_wheel_direction: i16 = blk: {
                    const wheelu32: u32 = event.dwButtonState >> 16;
                    const wheelu16: u16 = @truncate(wheelu32);
                    break :blk @bitCast(wheelu16);
                };

                const buttons: u16 = @truncate(event.dwButtonState);
                defer self.last_mouse_button_press = buttons;
                const button_xor = self.last_mouse_button_press ^ buttons;

                var event_type: Mouse.Type = .press;
                const btn: Mouse.Button = switch (button_xor) {
                    0x0000 => blk: {
                        if (event.dwEventFlags & 0x0004 > 0) {
                            if (mouse_wheel_direction > 0)
                                break :blk .wheel_up
                            else
                                break :blk .wheel_down;
                        }

                        if (buttons > 0 and event.dwEventFlags & 0x0001 > 0) {
                            event_type = .drag;
                            if (buttons & 0x0001 > 0) break :blk .left;
                            if (buttons & 0x0002 > 0) break :blk .right;
                            if (buttons & 0x0004 > 0) break :blk .middle;
                            if (buttons & 0x0008 > 0) break :blk .button_8;
                            if (buttons & 0x0010 > 0) break :blk .button_9;
                        }

                        if (event.dwEventFlags & 0x0001 > 0) event_type = .motion;
                        break :blk .none;
                    },
                    0x0001 => blk: {
                        if (buttons & 0x0001 == 0) event_type = .release;
                        break :blk .left;
                    },
                    0x0002 => blk: {
                        if (buttons & 0x0002 == 0) event_type = .release;
                        break :blk .right;
                    },
                    0x0004 => blk: {
                        if (buttons & 0x0004 == 0) event_type = .release;
                        break :blk .middle;
                    },
                    0x0008 => blk: {
                        if (buttons & 0x0008 == 0) event_type = .release;
                        break :blk .button_8;
                    },
                    0x0010 => blk: {
                        if (buttons & 0x0010 == 0) event_type = .release;
                        break :blk .button_9;
                    },
                    else => {
                        std.log.scoped(.term).warn("unknown mouse event: {}", .{event});
                        return null;
                    },
                };

                const shift: u32 = 0x0010;
                const alt: u32 = 0x0001 | 0x0002;
                const ctrl: u32 = 0x0004 | 0x0008;
                const mods: Mouse.Modifiers = .{
                    .shift = event.dwControlKeyState & shift > 0,
                    .alt = event.dwControlKeyState & alt > 0,
                    .ctrl = event.dwControlKeyState & ctrl > 0,
                };

                const mouse: Mouse = .{
                    .col = @as(i16, @bitCast(event.dwMousePosition.X)),
                    .row = @as(i16, @bitCast(event.dwMousePosition.Y)),
                    .mods = mods,
                    .type = event_type,
                    .button = btn,
                };
                return .{ .mouse = mouse };
            },
            0x0004 => {
                const ws = try winsizeFromHandle(self.out.handle);
                return .{ .winsize = ws };
            },
            0x0010 => {
                switch (record.Event.FocusEvent.bSetFocus) {
                    .FALSE => return .focus_out,
                    else => return .focus_in,
                }
            },
            else => {},
        }
        return null;
    }

    const union_unnamed_char = extern union {
        UnicodeChar: windows.WCHAR,
        AsciiChar: windows.CHAR,
    };

    pub const KEY_EVENT_RECORD = extern struct {
        bKeyDown: windows.BOOL,
        wRepeatCount: windows.WORD,
        wVirtualKeyCode: windows.WORD,
        wVirtualScanCode: windows.WORD,
        uChar: union_unnamed_char,
        dwControlKeyState: windows.DWORD,
    };

    pub const MOUSE_EVENT_RECORD = extern struct {
        dwMousePosition: windows.COORD,
        dwButtonState: windows.DWORD,
        dwControlKeyState: windows.DWORD,
        dwEventFlags: windows.DWORD,
    };

    pub const WINDOW_BUFFER_SIZE_RECORD = extern struct {
        dwSize: windows.COORD,
    };

    pub const MENU_EVENT_RECORD = extern struct {
        dwCommandId: windows.UINT,
    };

    pub const FOCUS_EVENT_RECORD = extern struct {
        bSetFocus: windows.BOOL,
    };

    const union_unnamed_event = extern union {
        KeyEvent: KEY_EVENT_RECORD,
        MouseEvent: MOUSE_EVENT_RECORD,
        WindowBufferSizeEvent: WINDOW_BUFFER_SIZE_RECORD,
        MenuEvent: MENU_EVENT_RECORD,
        FocusEvent: FOCUS_EVENT_RECORD,
    };

    pub const INPUT_RECORD = extern struct {
        EventType: windows.WORD,
        Event: union_unnamed_event,
    };
};

fn openConsole(name: [*:0]const u16, access: windows.DWORD, share: windows.DWORD) !windows.HANDLE {
    const handle = CreateFileW(name, access, share, null, open_existing, 0, null);
    if (handle == windows.INVALID_HANDLE_VALUE)
        return windows.unexpectedError(windows.GetLastError());
    return handle;
}

fn getConsoleMode(comptime T: type, handle: windows.HANDLE) !T {
    var mode: u32 = undefined;
    if (GetConsoleMode(handle, &mode) == .FALSE) return switch (windows.GetLastError()) {
        .INVALID_HANDLE => error.InvalidHandle,
        else => |e| windows.unexpectedError(e),
    };
    return @bitCast(mode);
}

fn setConsoleMode(handle: windows.HANDLE, mode: anytype) !void {
    if (SetConsoleMode(handle, @bitCast(mode)) == .FALSE) return switch (windows.GetLastError()) {
        .INVALID_HANDLE => error.InvalidHandle,
        else => |e| windows.unexpectedError(e),
    };
}

fn translateMods(mods: u32) Key.Modifiers {
    const left_alt: u32 = 0x0002;
    const right_alt: u32 = 0x0001;
    const left_ctrl: u32 = 0x0008;
    const right_ctrl: u32 = 0x0004;

    const caps: u32 = 0x0080;
    const num_lock: u32 = 0x0020;
    const shift: u32 = 0x0010;
    const alt: u32 = left_alt | right_alt;
    const ctrl: u32 = left_ctrl | right_ctrl;

    const alt_gr = (mods & right_alt > 0) and (mods & left_ctrl > 0);

    return .{
        .shift = mods & shift > 0,
        .alt = if (alt_gr) mods & left_alt > 0 else mods & alt > 0,
        .ctrl = if (alt_gr) mods & right_ctrl > 0 else mods & ctrl > 0,
        .caps_lock = mods & caps > 0,
        .num_lock = mods & num_lock > 0,
    };
}

fn winsizeFromHandle(handle: windows.HANDLE) !Winsize {
    var console_info: Tty.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (GetConsoleScreenBufferInfo(handle, &console_info) == .FALSE)
        return windows.unexpectedError(windows.GetLastError());
    const window_rect = console_info.srWindow;
    const width = window_rect.Right - window_rect.Left + 1;
    const height = window_rect.Bottom - window_rect.Top + 1;
    return .{
        .cols = @intCast(width),
        .rows = @intCast(height),
        .x_pixel = 0,
        .y_pixel = 0,
    };
}

fn readRecordBlocking(handle: windows.HANDLE) !Tty.INPUT_RECORD {
    var event_count: u32 = 0;
    var input_record: Tty.INPUT_RECORD = undefined;
    if (ReadConsoleInputW(handle, &input_record, 1, &event_count) == .FALSE)
        return windows.unexpectedError(windows.GetLastError());
    return input_record;
}

fn dummyTty() Tty {
    return .{
        .io = std.testing.io,
        .in = .{ .handle = undefined, .flags = .{ .nonblocking = false } },
        .out = .{ .handle = undefined, .flags = .{ .nonblocking = false } },
        .initial_codepage = 0,
        .initial_input_mode = .{},
        .initial_output_mode = .{},
    };
}

fn keyRecord(vk: windows.WORD, unicode: windows.WCHAR, down: windows.BOOL, mods: windows.DWORD) Tty.INPUT_RECORD {
    return .{
        .EventType = 0x0001,
        .Event = .{
            .KeyEvent = .{
                .bKeyDown = down,
                .wRepeatCount = 1,
                .wVirtualKeyCode = vk,
                .wVirtualScanCode = 0,
                .uChar = .{ .UnicodeChar = unicode },
                .dwControlKeyState = mods,
            },
        },
    };
}

extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn ReadConsoleInputW(
    hConsoleInput: windows.HANDLE,
    lpBuffer: *Tty.INPUT_RECORD,
    nLength: windows.DWORD,
    lpNumberOfEventsRead: *windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetNumberOfConsoleInputEvents(
    hConsoleInput: windows.HANDLE,
    lpcNumberOfEvents: *windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) windows.UINT;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: windows.HANDLE, lpMode: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: windows.HANDLE, dwMode: windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetConsoleOutputCP(wCodePageId: windows.UINT) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: windows.HANDLE,
    lpConsoleScreenBufferInfo: *Tty.CONSOLE_SCREEN_BUFFER_INFO,
) callconv(.winapi) windows.BOOL;

test "eventFromRecord maps a latin key press" {
    var tty = dummyTty();
    var parser: Parser = .{};
    var state: Tty.EventState = .{};
    const record = keyRecord(0x41, 'a', .TRUE, 0);
    const event = (try tty.eventFromRecord(&record, &state, &parser, null)).?;
    try std.testing.expectEqual(@as(u21, 'a'), event.key_press.codepoint);
    try std.testing.expectEqualStrings("a", event.key_press.text.?);
}

test "eventFromRecord maps a key release" {
    var tty = dummyTty();
    var parser: Parser = .{};
    var state: Tty.EventState = .{};
    const record = keyRecord(0x41, 'a', .FALSE, 0);
    const event = (try tty.eventFromRecord(&record, &state, &parser, null)).?;
    try std.testing.expectEqual(@as(u21, 'a'), event.key_release.codepoint);
}

test "eventFromRecord maps shift on an arrow key" {
    var tty = dummyTty();
    var parser: Parser = .{};
    var state: Tty.EventState = .{};
    const record = keyRecord(0x26, 0, .TRUE, 0x0010);
    const event = (try tty.eventFromRecord(&record, &state, &parser, null)).?;
    try std.testing.expectEqual(Key.up, event.key_press.codepoint);
    try std.testing.expect(event.key_press.mods.shift);
}

test "eventFromRecord maps focus and mouse press" {
    var tty = dummyTty();
    var parser: Parser = .{};
    var state: Tty.EventState = .{};

    const focus_record: Tty.INPUT_RECORD = .{
        .EventType = 0x0010,
        .Event = .{ .FocusEvent = .{ .bSetFocus = .TRUE } },
    };
    try std.testing.expectEqual(Event.focus_in, (try tty.eventFromRecord(&focus_record, &state, &parser, null)).?);

    const mouse_record: Tty.INPUT_RECORD = .{
        .EventType = 0x0002,
        .Event = .{
            .MouseEvent = .{
                .dwMousePosition = .{ .X = 3, .Y = 4 },
                .dwButtonState = 0x0001,
                .dwControlKeyState = 0,
                .dwEventFlags = 0,
            },
        },
    };
    const mouse = (try tty.eventFromRecord(&mouse_record, &state, &parser, null)).?.mouse;
    try std.testing.expectEqual(@as(i16, 3), mouse.col);
    try std.testing.expectEqual(@as(i16, 4), mouse.row);
    try std.testing.expectEqual(Mouse.Button.left, mouse.button);
    try std.testing.expectEqual(Mouse.Type.press, mouse.type);
}

test "WinsizeWatch reports in-band resize" {
    var watch = try WinsizeWatch.init();
    defer watch.deinit();
    var tty = dummyTty();
    try std.testing.expectError(error.ResizeInBand, watch.wait(&tty));
}
