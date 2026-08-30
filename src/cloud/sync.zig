//! Keep the local catalog snapshot current. The daemon holds no cloud credential for this document,
//! so any yuke user gets the model list, signed in or not.

const std = @import("std");
const bundle = @import("bundle.zig");
const catalog = @import("catalog.zig");
const http = @import("http.zig");
const catalog_store = @import("../database/catalog.zig");
const Database = @import("../database/database.zig").Database;

/// The executable variant carries only the providers that yuke can call. It decompresses to about
/// 185 KB, so this bound leaves generous room for growth.
const max_catalog_bytes = 1024 * 1024;

/// The full public catalog is 2.58 MB. This bound leaves room for account-specific model lists.
const max_bundle_bytes = 4 * 1024 * 1024;

/// Bound the ETag that the cloud returns. A weak validator adds a `W/` prefix.
const max_etag_bytes = 256;

/// The executable catalog omits every provider that yuke cannot call.
pub const catalog_path = "/api/v1/catalog?executable=true";

/// The account bundle carries routes and live credentials.
pub const providers_path = "/api/v1/providers";

/// The status that the control plane sends before its first catalog sync.
const status_unavailable = 503;

pub const Outcome = enum {
    /// The stored snapshot already matches the cloud.
    unchanged,
    /// The snapshot was replaced.
    updated,
    /// The cloud has not synced its catalog yet. Ask again later.
    unavailable,
};

/// Fetch the catalog and replace the snapshot when it changed.
/// A conditional request makes an unchanged catalog cost one small response.
pub fn refreshCatalog(
    gpa: std.mem.Allocator,
    client: *http.Client,
    db: *Database,
    base_url: []const u8,
) !Outcome {
    std.debug.assert(base_url.len != 0); // The caller resolves the control-plane URL.

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();

    const url = try std.mem.concat(scratch, u8, &.{ std.mem.trimEnd(u8, base_url, "/"), catalog_path });
    const stored_etag = (try catalog_store.etag(db, scratch)) orelse "";

    const body = try gpa.alloc(u8, max_catalog_bytes);
    defer gpa.free(body);
    var etag_buf: [max_etag_bytes]u8 = undefined;

    const response = try client.get(.{
        .url = url,
        .if_none_match = stored_etag,
        .body_out = body,
        .etag_out = &etag_buf,
    });

    if (response.status == http.status_not_modified) return .unchanged;
    if (response.status == status_unavailable) return .unavailable;
    if (response.status < 200 or response.status >= 300) return error.CatalogRejected;

    const doc = try catalog.decode(scratch, response.body);
    try catalog_store.replace(db, scratch, doc.providers, doc.catalog_rev, response.etag);
    return .updated;
}

pub const ProvidersOutcome = union(enum) {
    unchanged,
    updated: bundle.Snapshot,
};

/// Fetch the account bundle. The returned snapshot owns the document and the response ETag.
pub fn refreshProviders(
    gpa: std.mem.Allocator,
    client: *http.Client,
    base_url: []const u8,
    credential: []const u8,
    etag: []const u8,
) !ProvidersOutcome {
    std.debug.assert(base_url.len != 0);
    std.debug.assert(credential.len != 0);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const url = try std.mem.concat(arena.allocator(), u8, &.{ std.mem.trimEnd(u8, base_url, "/"), providers_path });

    const body = try gpa.alloc(u8, max_bundle_bytes);
    defer gpa.free(body);
    defer std.crypto.secureZero(u8, body);
    var etag_buf: [max_etag_bytes]u8 = undefined;

    const response = try client.get(.{
        .url = url,
        .if_none_match = etag,
        .bearer = credential,
        .body_out = body,
        .etag_out = &etag_buf,
    });

    if (response.status == http.status_not_modified) return .unchanged;
    if (response.status < 200 or response.status >= 300) return error.ProvidersRejected;
    return .{ .updated = try bundle.Snapshot.init(gpa, response.body, response.etag) };
}

const testing = std.testing;
const zio = @import("zio");

const ProvidersServer = struct {
    listener: *zio.net.Server = undefined,
    status: std.http.Status,
    body: []const u8,
    etag: []const u8,
    expect_etag: []const u8,
    saw_target: bool = false,
    saw_bearer: bool = false,
    saw_etag: bool = false,
    err: ?anyerror = null,
};

fn serveProvidersOnce(server: *ProvidersServer) void {
    serveProvidersOnceInner(server) catch |err| {
        server.err = err;
    };
}

fn serveProvidersOnceInner(s: *ProvidersServer) !void {
    const stream = try s.listener.accept(.{});
    defer stream.close();
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var reader = stream.reader(&read_buf);
    var writer = stream.writer(&write_buf);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();

    s.saw_target = std.mem.eql(u8, request.head.target, providers_path);
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization"))
            s.saw_bearer = std.mem.eql(u8, header.value, "Bearer device-secret");
        if (std.ascii.eqlIgnoreCase(header.name, "if-none-match"))
            s.saw_etag = std.mem.eql(u8, header.value, s.expect_etag);
    }

    const response_headers = [_]std.http.Header{.{ .name = "etag", .value = s.etag }};
    try request.respond(s.body, .{
        .status = s.status,
        .keep_alive = false,
        .extra_headers = &response_headers,
    });
}

const ProvidersClient = struct {
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    port: u16 = undefined,
    etag: []const u8,
    snapshot: ?bundle.Snapshot = null,
    unchanged: bool = false,
    err: ?anyerror = null,
};

fn fetchProvidersOnce(out: *ProvidersClient) void {
    fetchProvidersOnceInner(out) catch |err| {
        out.err = err;
    };
}

fn fetchProvidersOnceInner(out: *ProvidersClient) !void {
    var client: http.Client = .init(out.gpa, out.io);
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const base_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{out.port});
    const outcome = try refreshProviders(out.gpa, &client, base_url, "device-secret", out.etag);
    switch (outcome) {
        .unchanged => out.unchanged = true,
        .updated => |snapshot| out.snapshot = snapshot,
    }
}

fn exchangeProviders(server: *ProvidersServer, out: *ProvidersClient) !void {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const address = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(.{});
    defer listener.close();
    server.listener = &listener;
    out.gpa = testing.allocator;
    out.io = rt.io();
    out.port = listener.socket.address.ip.getPort();

    var server_task = try rt.spawn(serveProvidersOnce, .{server});
    var client_task = try rt.spawn(fetchProvidersOnce, .{out});
    client_task.join();
    server_task.join();
}

test "provider refresh sends the device bearer and owns the response" {
    const body =
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"acme","public_id":"p1","name":"Acme",
        \\ "base_url":"https://acme.example/v1","protocol":"openai_chat","cache":"unsupported","headers":[],
        \\ "auth":{"kind":"api_key","header":"authorization_bearer","status":"active","api_key":"secret"},"models":[]}]}
    ;
    var server: ProvidersServer = .{ .status = .ok, .body = body, .etag = "etag-2", .expect_etag = "etag-1" };
    var out: ProvidersClient = .{ .etag = "etag-1" };
    defer if (out.snapshot) |*snapshot| snapshot.deinit();
    try exchangeProviders(&server, &out);

    if (server.err) |err| return err;
    if (out.err) |err| return err;
    try testing.expect(server.saw_target);
    try testing.expect(server.saw_bearer);
    try testing.expect(server.saw_etag);
    try testing.expectEqualStrings("etag-2", out.snapshot.?.etag);
    try testing.expectEqualStrings("secret", out.snapshot.?.document.providers[0].auth.api_key.?);
}

test "provider refresh keeps the snapshot on a 304" {
    var server: ProvidersServer = .{ .status = .not_modified, .body = "", .etag = "etag-1", .expect_etag = "etag-1" };
    var out: ProvidersClient = .{ .etag = "etag-1" };
    try exchangeProviders(&server, &out);

    if (server.err) |err| return err;
    if (out.err) |err| return err;
    try testing.expect(server.saw_bearer);
    try testing.expect(server.saw_etag);
    try testing.expect(out.unchanged);
    try testing.expect(out.snapshot == null);
}
