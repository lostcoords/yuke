const xvaxis = @import("xvaxis/main.zig");

pub const Cell = xvaxis.Cell;
pub const Style = xvaxis.Style;
pub const Color = xvaxis.Color;
pub const Screen = xvaxis.Screen;
pub const Window = xvaxis.Window;
pub const Parser = xvaxis.Parser;
pub const Mouse = xvaxis.Mouse;
pub const gwidth = xvaxis.gwidth;
pub const unicode = xvaxis.unicode;

pub const Tty = @import("tty.zig").Tty;
pub const Winsize = @import("tty.zig").Winsize;
pub const WinsizeWatch = @import("tty.zig").WinsizeWatch;
pub const resize_in_band = @import("tty.zig").resize_in_band;
pub const Input = @import("input.zig").Input;
pub const Event = @import("input.zig").Event;
pub const Key = @import("input.zig").Key;
pub const Render = @import("render.zig").Render;

test {
    _ = @import("tty.zig");
    _ = @import("input.zig");
    _ = @import("render.zig");
    _ = xvaxis;
}
