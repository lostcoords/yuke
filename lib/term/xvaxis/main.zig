const std = @import("std");

pub const Vaxis = @import("Vaxis.zig");

pub const Key = @import("Key.zig");
pub const Cell = @import("Cell.zig");
pub const Segment = Cell.Segment;
pub const PrintOptions = Window.PrintOptions;
pub const Style = Cell.Style;
pub const Color = Cell.Color;
pub const Image = @import("Image.zig");
pub const Mouse = @import("Mouse.zig");
pub const Screen = @import("Screen.zig");
pub const AllocatingScreen = @import("InternalScreen.zig");
pub const Parser = @import("Parser.zig");
pub const Window = @import("Window.zig");
pub const gwidth = @import("gwidth.zig");
pub const ctlseqs = @import("ctlseqs.zig");
pub const Event = @import("event.zig").Event;
pub const unicode = @import("unicode.zig");

/// The size of the terminal screen
pub const Winsize = struct {
    rows: u16,
    cols: u16,
    x_pixel: u16,
    y_pixel: u16,
};

/// Initialize a Vaxis application.
pub fn init(io: std.Io, alloc: std.mem.Allocator, env_map: *const std.process.Environ.Map, opts: Vaxis.Options) !Vaxis {
    return Vaxis.init(io, alloc, env_map, opts);
}

pub const log_scopes = enum {
    vaxis,
};

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
