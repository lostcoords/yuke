//! `yuke types`: write the plugin API declarations into the profile's configuration directory, so an editor checks `index.js`.

const std = @import("std");

/// The plugin API and the file that names its modules. `mise run types` generates both, and CI fails when either is stale.
const declarations = [_]struct { name: []const u8, data: []const u8 }{
    .{ .name = "yuke.d.ts", .data = @embedFile("../js/app/generated/yuke.d.ts") },
    .{ .name = "yuke-modules.d.ts", .data = @embedFile("../js/app/generated/yuke-modules.d.ts") },
};

/// The editor project for the configuration directory. CI checks the declarations with these options, and a user's own file wins.
const jsconfig = @embedFile("plugin-jsconfig.json");

pub const Error = std.Io.Dir.CreateDirPathOpenError || std.Io.Dir.WriteFileError || std.Io.Writer.Error;

/// Write the declarations into `config_dir`, and `jsconfig.json` when none exists. Return the exit status.
pub fn run(io: std.Io, config_dir: ?[]const u8) Error!u8 {
    const path = config_dir orelse {
        std.log.err("yuke types: no configuration directory; set XDG_CONFIG_HOME or HOME", .{});
        return 1;
    };
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer dir.close(io);
    const wrote_project = try write(io, dir);

    var buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    for (declarations) |file| try out.interface.print("wrote {s}/{s}\n", .{ path, file.name });
    if (wrote_project) try out.interface.print("wrote {s}/jsconfig.json\n", .{path});
    try out.interface.flush();
    return 0;
}

/// Replace the declarations and create the project file when it is absent. Answer whether the project file was written.
fn write(io: std.Io, dir: std.Io.Dir) std.Io.Dir.WriteFileError!bool {
    for (declarations) |file| try dir.writeFile(io, .{ .sub_path = file.name, .data = file.data });
    dir.writeFile(io, .{ .sub_path = "jsconfig.json", .data = jsconfig, .flags = .{ .exclusive = true } }) catch |err| switch (err) {
        error.PathAlreadyExists => return false,
        else => |e| return e,
    };
    return true;
}

test "types refreshes the declarations and keeps the user's project file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expect(try write(io, tmp.dir));
    try tmp.dir.writeFile(io, .{ .sub_path = "jsconfig.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "yuke.d.ts", .data = "stale" });
    try std.testing.expect(!try write(io, tmp.dir));

    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("{}", try tmp.dir.readFile(io, "jsconfig.json", &buf));
    const refreshed = try tmp.dir.readFileAlloc(io, "yuke.d.ts", std.testing.allocator, .limited(declarations[0].data.len + 1));
    defer std.testing.allocator.free(refreshed);
    try std.testing.expectEqualStrings(declarations[0].data, refreshed);
}
