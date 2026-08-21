//! Command-line driver for schema-validated typed query generation.

const std = @import("std");
const zqlite = @import("zqlite");
const generator = @import("sqlgen");

const usage =
    "usage: yuke-sqlgen --migrations <dir> --queries <dir> --queries-out <file> [--check] [--quiet]";

const Options = struct {
    migrations: []const u8,
    queries: []const u8,
    queries_out: []const u8,
    check: bool = false,
    quiet: bool = false,
};

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.log.err("sqlgen failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const options = parseOptions(args[1..]) orelse {
        std.log.err("{s}", .{usage});
        std.process.exit(2);
    };

    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.NoMutex);
    defer conn.tryClose() catch unreachable;
    const migration_count = try applyMigrations(a, init.io, conn, options.migrations);

    const definitions = try loadQueries(a, init.io, options.queries);
    var resolved = try a.alloc(generator.Resolved, definitions.len);
    for (definitions, 0..) |definition, i| {
        resolved[i] = generator.resolve(a, conn, definition) catch |err| {
            std.log.err("query {s}: {s}", .{ definition.name, @errorName(err) });
            return err;
        };
    }

    var output: std.Io.Writer.Allocating = .init(a);
    try generator.emit(a, &output.writer, resolved);
    const generated = output.written();
    try validateZig(a, generated);

    const cwd = std.Io.Dir.cwd();
    if (options.check) {
        const existing = cwd.readFileAlloc(init.io, options.queries_out, a, .unlimited) catch
            return error.GeneratedFileMissing;
        if (!std.mem.eql(u8, existing, generated)) return error.GeneratedFileStale;
    } else {
        try writeAtomic(a, init.io, options.queries_out, generated);
    }

    if (!options.quiet) {
        std.log.info("{s}: {d} bytes, {d} migrations, {d} queries", .{
            options.queries_out,
            generated.len,
            migration_count,
            resolved.len,
        });
    }
}

fn writeAtomic(a: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8) !void {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);
    const temporary_path = try std.fmt.allocPrint(a, "{s}.tmp-{s}", .{ path, suffix });

    const cwd = std.Io.Dir.cwd();
    var temporary_exists = false;
    defer if (temporary_exists) cwd.deleteFile(io, temporary_path) catch {};
    try cwd.writeFile(io, .{
        .sub_path = temporary_path,
        .data = data,
        .flags = .{ .exclusive = true },
    });
    temporary_exists = true;
    try cwd.rename(temporary_path, cwd, path, io);
    temporary_exists = false;
}

fn parseOptions(args: []const [:0]const u8) ?Options {
    var migrations: ?[]const u8 = null;
    var queries: ?[]const u8 = null;
    var queries_out: ?[]const u8 = null;
    var check = false;
    var quiet = false;
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--check")) {
            check = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--migrations")) {
            if (i + 1 >= args.len or migrations != null) return null;
            migrations = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, arg, "--queries")) {
            if (i + 1 >= args.len or queries != null) return null;
            queries = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, arg, "--queries-out")) {
            if (i + 1 >= args.len or queries_out != null) return null;
            queries_out = args[i + 1];
            i += 2;
        } else {
            return null;
        }
    }
    return .{
        .migrations = migrations orelse return null,
        .queries = queries orelse return null,
        .queries_out = queries_out orelse return null,
        .check = check,
        .quiet = quiet,
    };
}

fn applyMigrations(a: std.mem.Allocator, io: std.Io, conn: zqlite.Conn, path: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    const names = try sqlFileNames(a, io, dir);
    if (names.len == 0) return error.NoMigrationFiles;

    for (names) |name| {
        const source = try dir.readFileAlloc(io, name, a, .unlimited);
        const source_z = try a.dupeZ(u8, source);
        conn.execNoArgs(source_z) catch |err| {
            std.log.err("migration {s}: {s}", .{ name, @errorName(err) });
            return err;
        };
    }
    return names.len;
}

fn loadQueries(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const generator.Definition {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    const names = try sqlFileNames(a, io, dir);
    if (names.len == 0) return error.NoQueryFiles;

    var definitions: std.ArrayList(generator.Definition) = .empty;
    for (names) |name| {
        const source = try dir.readFileAlloc(io, name, a, .unlimited);
        const file_definitions = generator.parse(a, source) catch |err| {
            std.log.err("query source {s}: {s}", .{ name, @errorName(err) });
            return err;
        };
        for (file_definitions) |definition| {
            for (definitions.items) |existing| {
                if (std.mem.eql(u8, definition.name, existing.name)) {
                    std.log.err("duplicate query name: {s}", .{definition.name});
                    return error.DuplicateQuery;
                }
            }
            try definitions.append(a, definition);
        }
    }
    return definitions.toOwnedSlice(a);
}

fn sqlFileNames(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sql")) continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.toOwnedSlice(a);
}

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn validateZig(a: std.mem.Allocator, source: []const u8) !void {
    const source_z = try a.dupeZ(u8, source);
    var tree = try std.zig.Ast.parse(a, source_z, .zig);
    defer tree.deinit(a);
    if (tree.errors.len != 0) return error.InvalidGeneratedZig;
}
