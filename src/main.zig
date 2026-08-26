//! The yuke process entry. Default mode is the TUI.

const std = @import("std");
const cli = @import("cli.zig");
const daemon_app = @import("daemon/app.zig");
const tui_app = @import("tui/app.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    std.debug.assert(args.len >= 1);
    const mode = cli.parseMode(args[1..]) catch |err| switch (err) {
        error.Help => {
            var buf: [128]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(init.io, &buf);
            try stdout.interface.print("{s}\n", .{cli.usage});
            try stdout.interface.flush();
            return;
        },
        error.Conflict => {
            std.log.err("choose one of --tui or --daemon", .{});
            std.log.err("{s}", .{cli.usage});
            std.process.exit(2);
        },
        error.UnknownFlag => {
            std.log.err("{s}", .{cli.usage});
            std.process.exit(2);
        },
    };
    switch (mode) {
        .tui => try tui_app.run(init.gpa, init.environ_map),
        .daemon => try daemon_app.run(init),
    }
}
