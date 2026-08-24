const std = @import("std");
const vaxis = @import("vaxis");

pub const Cell = vaxis.Cell;
pub const Style = vaxis.Style;
pub const Screen = vaxis.Screen;
pub const Window = vaxis.Window;
pub const Parser = vaxis.Parser;

pub const Tty = @import("tty.zig").Tty;
pub const Winsize = @import("tty.zig").Winsize;
pub const Input = @import("input.zig").Input;
pub const Event = @import("input.zig").Event;
pub const Key = @import("input.zig").Key;

test {
    _ = @import("tty.zig");
    _ = @import("input.zig");
}
