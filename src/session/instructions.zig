//! Load the two instruction roots and preserve their exact source bytes.

const std = @import("std");
const proto = @import("proto");
const paths = @import("../paths.zig");

pub const max_file_bytes = 256 * 1024;
pub const Snapshot = struct {
    source: proto.instructions.InstructionSource,
    text: []const u8,
};

pub fn load(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, workspace: []const u8, diagnostic: ?*?[]const u8) ![]const Snapshot {
    std.debug.assert(std.fs.path.isAbsolute(workspace));
    const home = paths.homeDir(env);
    const global = if (home != null and std.fs.path.isAbsolute(home.?)) try std.fs.path.join(arena, &.{ home.?, ".agents", "AGENTS.md" }) else null;
    const local = try std.fs.path.join(arena, &.{ workspace, "AGENTS.md" });
    var result: [2]Snapshot = undefined;
    var count: usize = 0;
    candidates: for ([_]?[]const u8{ global, local }, [_]proto.instructions.InstructionScope{ .global, .workspace }) |candidate, scope| {
        const path = candidate orelse continue;
        const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(io, path, arena) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.OutOfMemory, error.Canceled => return err,
            else => return refuse(arena, diagnostic, path, @errorName(err)),
        };
        if (!std.unicode.utf8ValidateSlice(canonical)) return refuse(arena, diagnostic, path, "the source path is not valid UTF-8");
        for (result[0..count]) |*old| {
            if (!std.mem.eql(u8, old.source.canonical_path, canonical)) continue;
            old.source.scope = scope;
            old.source.path = path;
            continue :candidates;
        }
        const stat = std.Io.Dir.cwd().statFile(io, canonical, .{}) catch |err| switch (err) {
            error.Canceled => return err,
            else => return refuse(arena, diagnostic, path, @errorName(err)),
        };
        if (stat.kind != .file) return refuse(arena, diagnostic, path, "the source is not a regular file");
        if (stat.size > max_file_bytes) return refuse(arena, diagnostic, path, "the file exceeds 256 KiB");
        const text = std.Io.Dir.cwd().readFileAlloc(io, canonical, arena, .limited(max_file_bytes)) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            error.StreamTooLong => return refuse(arena, diagnostic, path, "the file exceeds 256 KiB"),
            else => return refuse(arena, diagnostic, path, @errorName(err)),
        };
        if (!std.unicode.utf8ValidateSlice(text)) return refuse(arena, diagnostic, path, "the file is not valid UTF-8");
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
        std.debug.assert(count < result.len);
        result[count] = .{ .source = .{ .scope = scope, .path = path, .canonical_path = canonical, .content_hash = .bytes(hash) }, .text = text };
        count += 1;
    }
    return arena.dupe(Snapshot, result[0..count]);
}

fn refuse(arena: std.mem.Allocator, diagnostic: ?*?[]const u8, path: []const u8, reason: []const u8) error{ InvalidInstructions, OutOfMemory } {
    if (diagnostic) |out| out.* = std.fmt.allocPrint(arena, "Cannot load AGENTS.md at {s}: {s}", .{ path, reason }) catch return error.OutOfMemory;
    return error.InvalidInstructions;
}

pub fn render(arena: std.mem.Allocator, snapshots: []const Snapshot) ![]const u8 {
    std.debug.assert(snapshots.len <= 2);
    if (snapshots.len == 0) return "";
    var sections: [5][]const u8 = undefined;
    sections[0] = "Project instructions follow. Explicit user instructions take precedence. Workspace instructions override global instructions where they conflict.";
    for (snapshots, 0..) |snapshot, i| {
        std.debug.assert(snapshot.text.len <= max_file_bytes);
        const escaped = try std.json.Stringify.valueAlloc(arena, snapshot.source.path, .{});
        sections[i * 2 + 1] = try std.fmt.allocPrint(arena, "\n\n## AGENTS.md ({s})\nScope: {s}.\n\n", .{ escaped[1 .. escaped.len - 1], @tagName(snapshot.source.scope) });
        sections[i * 2 + 2] = snapshot.text;
    }
    return std.mem.concat(arena, u8, sections[0 .. snapshots.len * 2 + 1]);
}

test "instruction roots preserve literal text and omit nested files" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.agents");
    try tmp.dir.createDirPath(std.testing.io, "work/nested");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    const home = try std.fs.path.join(scratch, &.{ root, "home" });
    const workspace = try std.fs.path.join(scratch, &.{ root, "work" });
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put(if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME", home);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "work/nested/AGENTS.md", .data = "nested must not load" });
    try std.testing.expectEqual(@as(usize, 0), (try load(scratch, std.testing.io, &env, workspace, null)).len);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/.agents/AGENTS.md", .data = "global ${workspace}\n" });
    const global = try load(scratch, std.testing.io, &env, workspace, null);
    try std.testing.expectEqual(@as(usize, 1), global.len);
    try std.testing.expectEqual(.global, global[0].source.scope);
    try std.testing.expectEqualStrings("global ${workspace}\n", global[0].text);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "work/AGENTS.md", .data = "local ${unknown}" });
    const both = try load(scratch, std.testing.io, &env, workspace, null);
    try std.testing.expectEqual(@as(usize, 2), both.len);
    try std.testing.expectEqual(.global, both[0].source.scope);
    try std.testing.expectEqual(.workspace, both[1].source.scope);
    const text = try render(scratch, both);
    try std.testing.expect(std.mem.indexOf(u8, text, global[0].text).? < std.mem.indexOf(u8, text, "local ${unknown}").?);
    try std.testing.expect(std.mem.indexOf(u8, text, "nested must not load") == null);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("local ${unknown}", &hash, .{});
    try std.testing.expectEqualSlices(u8, &hash, &both[1].source.content_hash.raw);
    try tmp.dir.deleteFile(std.testing.io, "home/.agents/AGENTS.md");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "work/AGENTS.md", .data = "" });
    const empty = try load(scratch, std.testing.io, &env, workspace, null);
    try std.testing.expectEqual(@as(usize, 1), empty.len);
    try std.testing.expectEqualStrings("", empty[0].text);
    try std.testing.expectEqual(.workspace, empty[0].source.scope);
}

test "instruction symlinks share one snapshot and can leave the workspace" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.agents");
    try tmp.dir.createDirPath(std.testing.io, "work");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "shared.md", .data = "shared instructions" });
    try tmp.dir.symLink(std.testing.io, "../../shared.md", "home/.agents/AGENTS.md", .{});
    try tmp.dir.symLink(std.testing.io, "../shared.md", "work/AGENTS.md", .{});
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put(if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME", try std.fs.path.join(a, &.{ root, "home" }));
    const snapshots = try load(a, std.testing.io, &env, try std.fs.path.join(a, &.{ root, "work" }), null);
    try std.testing.expectEqual(@as(usize, 1), snapshots.len);
    try std.testing.expectEqual(.workspace, snapshots[0].source.scope);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "shared.md" }), snapshots[0].source.canonical_path);
    try std.testing.expectEqualStrings("shared instructions", snapshots[0].text);
}

test "invalid instruction sources report their path" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var diagnostic: ?[]const u8 = null;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "\xff" });
    try std.testing.expectError(error.InvalidInstructions, load(a, std.testing.io, &env, root, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?, root) != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?, "UTF-8") != null);
    const large = try a.alloc(u8, max_file_bytes + 1);
    @memset(large, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = large });
    try std.testing.expectError(error.InvalidInstructions, load(a, std.testing.io, &env, root, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?, "256 KiB") != null);
    try tmp.dir.deleteFile(std.testing.io, "AGENTS.md");
    try tmp.dir.createDir(std.testing.io, "AGENTS.md", .default_dir);
    try std.testing.expectError(error.InvalidInstructions, load(a, std.testing.io, &env, root, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?, "regular file") != null);
}
