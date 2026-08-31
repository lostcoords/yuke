//! Fetch the account bundle. It holds live credentials, so it stays in memory and never reaches SQLite.

const std = @import("std");
const bundle = @import("bundle.zig");
const http = @import("../net/http.zig");

/// The full public catalog is 2.58 MB. This bound leaves room for account-specific model lists.
const max_bundle_bytes = 4 * 1024 * 1024;

/// Bound the ETag that the control plane returns. A weak validator adds a `W/` prefix.
const max_etag_bytes = 256;

/// The account bundle carries routes and live credentials.
pub const providers_path = "/api/v1/providers";

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
    var client: http.Client = .init(out.gpa, out.io, .none);
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
        \\{"version":1,"catalog_rev":null,"providers":[{"id":"acme","name":"Acme",
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
