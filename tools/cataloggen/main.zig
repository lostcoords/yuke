//! Command-line driver that bakes one catalog document into the AI module.

const std = @import("std");
const generator = @import("cataloggen");

const usage = "usage: yuke-cataloggen --out <file> [--url <url> | --catalog <file>] [--check] [--quiet]";

/// The control plane serves the executable variant, which omits every provider yuke cannot call.
const default_url = "https://platform.yuke.sh/api/v1/catalog?executable=true";

/// The executable document is about 200 KB. This ceiling stops a runaway response.
const max_catalog_bytes = 8 << 20;

const Options = struct {
    out: []const u8,
    /// Read the document from this file. A null path fetches `url` instead.
    catalog: ?[]const u8 = null,
    url: []const u8 = default_url,
    check: bool = false,
    quiet: bool = false,
};

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.log.err("cataloggen failed: {s}", .{@errorName(err)});
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

    const cwd = std.Io.Dir.cwd();
    const source = if (options.catalog) |path|
        try cwd.readFileAlloc(init.io, path, a, .unlimited)
    else
        try fetch(a, init.io, options.url, options.quiet);

    var output: std.Io.Writer.Allocating = .init(a);
    const stats = try generator.emit(a, &output.writer, source);
    const generated = output.written();
    try validateZig(a, generated);

    // A degraded name leaves a working default, so it is a warning and never a failure.
    for (stats.unknown) |name| std.log.warn("catalog names {s}, which this build does not know", .{name});
    if (stats.providers_without_env != 0) {
        std.log.warn("{d} providers name no environment variable", .{stats.providers_without_env});
    }

    if (options.check) {
        const existing = cwd.readFileAlloc(init.io, options.out, a, .unlimited) catch
            return error.GeneratedFileMissing;
        if (!std.mem.eql(u8, existing, generated)) return error.GeneratedFileStale;
    } else {
        try writeAtomic(a, init.io, options.out, generated);
    }

    if (!options.quiet) {
        std.log.info("{s}: {d} bytes, {d} providers, {d} models", .{
            options.out,
            generated.len,
            stats.providers,
            stats.models,
        });
    }
}

/// Read the catalog from the control plane. It needs no credential.
/// This asks for no encoding, so the server inflates and the tool needs no decompressor.
fn fetch(a: std.mem.Allocator, io: std.Io, url: []const u8, quiet: bool) ![]u8 {
    if (!quiet) std.log.info("fetching {s}", .{url});
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();

    var request = try client.request(.GET, try std.Uri.parse(url), .{
        .headers = .{ .accept_encoding = .omit },
    });
    defer request.deinit();
    try request.sendBodiless();

    var redirect_buffer: [2048]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) {
        std.log.err("catalog request answered HTTP {d}", .{@intFromEnum(response.head.status)});
        return error.CatalogUnavailable;
    }

    var transfer_buffer: [4096]u8 = undefined;
    return response.reader(&transfer_buffer).allocRemaining(a, .limited(max_catalog_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.CatalogTooLarge,
        else => |e| e,
    };
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
    var catalog: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var out: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, arg, "--catalog")) {
            if (i + 1 >= args.len or catalog != null) return null;
            catalog = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, arg, "--url")) {
            if (i + 1 >= args.len or url != null) return null;
            url = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, arg, "--out")) {
            if (i + 1 >= args.len or out != null) return null;
            out = args[i + 1];
            i += 2;
        } else {
            return null;
        }
    }
    // A file and a URL name two different documents, so the run cannot hold both.
    if (catalog != null and url != null) return null;
    return .{
        .out = out orelse return null,
        .catalog = catalog,
        .url = url orelse default_url,
        .check = check,
        .quiet = quiet,
    };
}

fn validateZig(a: std.mem.Allocator, source: []const u8) !void {
    const source_z = try a.dupeZ(u8, source);
    var tree = try std.zig.Ast.parse(a, source_z, .zig);
    defer tree.deinit(a);
    if (tree.errors.len != 0) return error.InvalidGeneratedZig;
}
