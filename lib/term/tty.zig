const builtin = @import("builtin");
const xvaxis = @import("xvaxis/main.zig");
const tty_windows = @import("tty_windows.zig");
const tty_posix = @import("tty_posix.zig");

pub const Winsize = xvaxis.Winsize;

/// True when the OS reports resize as an input event.
pub const resize_in_band = builtin.os.tag == .windows;

pub const Tty = switch (builtin.os.tag) {
    .windows => tty_windows.Tty,
    else => tty_posix.Tty,
};

pub const WinsizeWatch = switch (builtin.os.tag) {
    .windows => tty_windows.WinsizeWatch,
    else => tty_posix.WinsizeWatch,
};

test {
    _ = Tty;
    _ = WinsizeWatch;
    switch (builtin.os.tag) {
        .windows => _ = tty_windows,
        else => _ = tty_posix,
    }
}
