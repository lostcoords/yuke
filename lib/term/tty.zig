const std = @import("std");
const builtin = @import("builtin");
const xvaxis = @import("xvaxis/main.zig");

pub const Winsize = xvaxis.Winsize;

/// True when the OS reports resize as an input event.
pub const resize_in_band = builtin.os.tag == .windows;

pub const Tty = switch (builtin.os.tag) {
    .windows => @import("tty_windows.zig").Tty,
    else => @import("tty_posix.zig").Tty,
};

pub const WinsizeWatch = switch (builtin.os.tag) {
    .windows => @import("tty_windows.zig").WinsizeWatch,
    else => @import("tty_posix.zig").WinsizeWatch,
};

test "resize_in_band matches the OS" {
    try std.testing.expectEqual(builtin.os.tag == .windows, resize_in_band);
}

test {
    _ = Tty;
    _ = WinsizeWatch;
    switch (builtin.os.tag) {
        .windows => _ = @import("tty_windows.zig"),
        else => _ = @import("tty_posix.zig"),
    }
}
