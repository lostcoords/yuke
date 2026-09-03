//! Keep the open catalog snapshot current. This document needs no credential.

const std = @import("std");
const feed = @import("feed.zig");
const store = @import("store.zig");
const http = @import("../net/http.zig");
const Database = @import("../store/store.zig").Database;

/// Bound the executable catalog, which decompresses to about 185 KB today.
const max_catalog_bytes = 1024 * 1024;

/// Bound the ETag that the control plane returns. A weak validator adds a `W/` prefix.
pub const max_etag_bytes = 256;

/// The executable catalog omits every provider that yuke cannot call.
pub const catalog_path = "/api/v1/catalog?executable=true";

/// The status that the control plane sends before its first catalog sync.
const status_unavailable = 503;

pub const Outcome = union(enum) {
    /// The stored snapshot already matches the cloud.
    unchanged,
    /// The store holds the new rows. This ETag borrows the caller buffer until the caller commits it.
    updated: []const u8,
    /// The cloud has not synced its catalog yet. Ask again later.
    unavailable,
};

/// Fetch the catalog, replace the stored rows, and return the ETag for the caller to commit.
pub fn refreshCatalog(
    gpa: std.mem.Allocator,
    client: *http.Client,
    db: *Database,
    base_url: []const u8,
    etag_out: []u8,
) !Outcome {
    std.debug.assert(base_url.len != 0); // The caller resolves the control-plane URL.

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();

    const url = try std.mem.concat(scratch, u8, &.{ std.mem.trimEnd(u8, base_url, "/"), catalog_path });
    const stored_etag = (try store.etag(db, scratch)) orelse "";

    const body = try gpa.alloc(u8, max_catalog_bytes);
    defer gpa.free(body);

    const response = try client.get(.{
        .url = url,
        .if_none_match = stored_etag,
        .body_out = body,
        .etag_out = etag_out,
    });

    if (response.status == http.status_not_modified) return .unchanged;
    if (response.status == status_unavailable) return .unavailable;
    if (response.status < 200 or response.status >= 300) return error.CatalogRejected;

    const doc = try feed.decode(scratch, response.body);
    try store.replace(db, scratch, doc.providers);
    return .{ .updated = response.etag };
}

const testing = std.testing;
const zio = @import("zio");

const CatalogServer = struct {
    listener: *zio.net.Server = undefined,
    status: std.http.Status,
    body: []const u8,
    etag: []const u8,
    /// Delay the response until the client timeout expires.
    delay_ms: u32 = 0,
    saw_conditional: bool = false,
    err: ?anyerror = null,
};

fn serveCatalogOnce(s: *CatalogServer) void {
    serveCatalogOnceInner(s) catch |err| {
        s.err = err;
    };
}

fn serveCatalogOnceInner(s: *CatalogServer) !void {
    const stream = try s.listener.accept(.{});
    defer stream.close();
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var reader = stream.reader(&read_buf);
    var writer = stream.writer(&write_buf);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();

    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "if-none-match")) s.saw_conditional = true;
    }

    if (s.delay_ms != 0) try zio.sleep(.fromMilliseconds(s.delay_ms));

    const response_headers = [_]std.http.Header{.{ .name = "etag", .value = s.etag }};
    try request.respond(s.body, .{
        .status = s.status,
        .keep_alive = false,
        .extra_headers = &response_headers,
    });
}

const CatalogClient = struct {
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    port: u16 = undefined,
    db: *Database,
    timeout: std.Io.Timeout = .none,
    etag_buf: [max_etag_bytes]u8 = undefined,
    outcome: ?Outcome = null,
    err: ?anyerror = null,
};

fn fetchCatalogOnce(out: *CatalogClient) void {
    fetchCatalogOnceInner(out) catch |err| {
        out.err = err;
    };
}

fn fetchCatalogOnceInner(out: *CatalogClient) !void {
    var client: http.Client = .init(out.gpa, out.io, out.timeout);
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const base_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{out.port});
    out.outcome = try refreshCatalog(out.gpa, &client, out.db, base_url, &out.etag_buf);
}

fn exchangeCatalog(server: *CatalogServer, out: *CatalogClient) !void {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const address = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(.{});
    defer listener.close();
    server.listener = &listener;
    out.gpa = testing.allocator;
    out.io = rt.io();
    out.port = listener.socket.address.ip.getPort();

    var server_task = try rt.spawn(serveCatalogOnce, .{server});
    var client_task = try rt.spawn(fetchCatalogOnce, .{out});
    client_task.join();
    server_task.join();
}

test "a 503 catalog reply reports unavailable and stores nothing" {
    var db = try Database.openTest();
    defer db.deinit();

    var server: CatalogServer = .{ .status = .service_unavailable, .body = "", .etag = "etag-1" };
    var out: CatalogClient = .{ .db = &db };
    try exchangeCatalog(&server, &out);

    if (out.err) |err| return err;
    try testing.expect(out.outcome.? == .unavailable);

    // A 503 response stores no ETag.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try store.etag(&db, arena.allocator())) == null);
}

// The decoder accepts only a SHA-512 hexadecimal digest.
const test_document = "{\"version\":1,\"catalog_rev\":\"" ++ "ab" ** 64 ++ "\",\"providers\":[]}";

test "a catalog fetch stores the rows and returns the etag to the caller" {
    var db = try Database.openTest();
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var server: CatalogServer = .{ .status = .ok, .body = test_document, .etag = "etag-2" };
    var out: CatalogClient = .{ .db = &db };
    try exchangeCatalog(&server, &out);

    if (server.err) |err| return err;
    if (out.err) |err| return err;
    try testing.expectEqualStrings("etag-2", out.outcome.?.updated);
    try testing.expect(!server.saw_conditional); // No stored ETag sends no If-None-Match.

    // The caller stores the ETag after it rebuilds, so the fetch leaves none.
    try testing.expect((try store.etag(&db, arena.allocator())) == null);
}

test "a stalled control plane fails the request at the timeout" {
    var db = try Database.openTest();
    defer db.deinit();

    var server: CatalogServer = .{ .status = .ok, .body = "{}", .etag = "", .delay_ms = 400 };
    var out: CatalogClient = .{
        .db = &db,
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(50) } },
    };
    try exchangeCatalog(&server, &out);

    // The client returns a timeout error before the delayed response arrives.
    try testing.expectEqual(http.Error.CloudTimeout, out.err.?);
    try testing.expect(out.outcome == null);
}
