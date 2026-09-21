//! A loopback HTTP peer shared by the tests and benchmarks.

const std = @import("std");
const http = @import("native/http.zig");

pub const Mode = enum { reply, echo, head, put, patch, delete, empty, hints, missing, redirect, limit, oversize, chunked, truncated, headers, header_bytes, utf8, malformed, bad_status, compressed, stall, slow_body, oversized_chunk, chunk_limit, close_delimited, close, silent_close, gated, partial_head, upload_stall, headers_limit, header_bytes_limit, close_limit, close_oversize, sse };

pub const Peer = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    url: []u8,
    tasks: std.Io.Group = .init,
    wake: ?*std.Io.Event = null,
    connections: std.atomic.Value(usize) = .init(0),
    requests: std.atomic.Value(usize) = .init(0),
    once: bool = false,
    failure_at: usize = 0,
    release: std.Io.Event = .unset,
    mode: Mode,
    ready: std.Io.Event = .unset,
    failure: ?anyerror = null,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, mode: Mode) !*Peer {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var server = try address.listen(io, .{});
        errdefer server.deinit(io);
        const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/path?q=a%20b", .{server.socket.address.getPort()});
        errdefer gpa.free(url);
        const self = try gpa.create(Peer);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .server = server, .url = url, .mode = mode };
        try self.tasks.concurrent(io, accept, .{self});
        return self;
    }

    pub fn stop(self: *Peer) void {
        self.tasks.cancel(self.io);
    }

    pub fn destroy(self: *Peer) void {
        self.stop();
        self.server.deinit(self.io);
        self.gpa.free(self.url);
        self.gpa.destroy(self);
    }

    fn accept(self: *Peer) void {
        while (true) {
            const stream = self.server.accept(self.io) catch return;
            _ = self.connections.fetchAdd(1, .monotonic);
            self.tasks.concurrent(self.io, serve, .{ self, stream }) catch {
                stream.close(self.io);
                return;
            };
        }
    }

    fn serve(self: *Peer, stream: std.Io.net.Stream) void {
        defer stream.close(self.io);
        self.exchange(stream) catch |err| switch (err) {
            error.Canceled, error.ReadFailed, error.WriteFailed, error.HttpConnectionClosing => {},
            else => {
                self.failure = err;
            },
        };
    }

    fn pause(self: *Peer) !void {
        try self.release.waitTimeout(self.io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(3) } });
    }

    fn exchange(self: *Peer, stream: std.Io.net.Stream) !void {
        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &read_buf);
        var writer = stream.writer(self.io, &write_buf);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        while (true) {
            var request = try server.receiveHead();
            const number = self.requests.fetchAdd(1, .acq_rel);
            const mode = if (self.once and number != self.failure_at) Mode.reply else self.mode;
            switch (mode) {
                .stall, .upload_stall => {},
                .partial_head => {
                    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Len");
                },
                .echo => {
                    if (request.head.method != .POST) return error.UnexpectedRequest;
                    if (!std.mem.eql(u8, "/path?q=a%20b", request.head.target)) return error.UnexpectedRequest;
                    var it = request.iterateHeaders();
                    var seen: u8 = 0;
                    while (it.next()) |header| {
                        if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                            if (!std.mem.eql(u8, "application/json", header.value)) return error.UnexpectedRequest;
                            seen += 1;
                        }
                        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                            if (!std.mem.eql(u8, "Bearer test", header.value)) return error.UnexpectedRequest;
                            seen += 1;
                        }
                        if (std.ascii.eqlIgnoreCase(header.name, "user-agent")) {
                            if (!std.mem.eql(u8, "yuke-test", header.value)) return error.UnexpectedRequest;
                            seen += 1;
                        }
                        if (std.ascii.eqlIgnoreCase(header.name, "accept-encoding")) return error.UnexpectedRequest;
                    }
                    if (seen != 3) return error.UnexpectedRequest;
                    var transfer: [1024]u8 = undefined;
                    const body = try request.readerExpectNone(&transfer).allocRemaining(self.gpa, .limited(1024));
                    defer self.gpa.free(body);
                    try request.respond(body, .{ .keep_alive = false, .extra_headers = &.{
                        .{ .name = "X-Name", .value = "first" },   .{ .name = "x-name", .value = "second" },
                        .{ .name = "__proto__", .value = "safe" },
                    } });
                },
                .put, .patch, .delete => {
                    const expected: std.http.Method = switch (mode) {
                        .put => .PUT,
                        .patch => .PATCH,
                        .delete => .DELETE,
                        else => unreachable,
                    };
                    if (expected != request.head.method) return error.UnexpectedRequest;
                    if (expected.requestHasBody() and request.head.content_length != 0) return error.UnexpectedRequest;
                    try request.respond("ok", .{ .keep_alive = false });
                },
                .empty => {
                    try writer.interface.writeAll("HTTP/1.1 204 No Content\r\nConnection: keep-alive\r\n\r\n");
                },
                .hints => {
                    try writer.interface.writeAll("HTTP/1.1 103 Early Hints\r\nLink: </style.css>\r\n\r\nHTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
                },
                .bad_status => {
                    try writer.interface.writeAll("HTTP/1.1 abc Invalid\r\nContent-Length: 0\r\n\r\n");
                },
                .reply, .close, .silent_close, .gated => {
                    if (mode == .gated) {
                        self.announce();
                        try self.pause();
                    }
                    try request.respond("{\"ok\":true}", .{ .keep_alive = mode != .close });
                    if (mode == .reply or mode == .gated) continue;
                },
                .head => {
                    if (request.head.method != .HEAD) return error.UnexpectedRequest;
                    try request.respond("not a response body", .{ .keep_alive = false });
                },
                .missing => try request.respond("{\"error\":\"missing\"}", .{ .status = .not_found, .keep_alive = false }),
                .redirect => {
                    try writer.interface.writeAll("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/leak\r\nContent-Encoding: gzip\r\nContent-Length: 100\r\n\r\n");
                },
                .limit => try request.respond("x" ** http.max_response_bytes, .{ .keep_alive = false }),
                .oversize => try request.respond("x" ** (http.max_response_bytes + 1), .{ .keep_alive = false }),
                .chunked => {
                    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\na\x00b\r\n2\r\ncd\r\n0\r\n\r\n");
                },
                .slow_body => {
                    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nx");
                },
                .header_bytes_limit => {
                    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-Large: " ++ "x" ** 8170 ++ "\r\n\r\nok");
                },
                .close_limit, .close_oversize => {
                    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n");
                    const length = http.max_response_bytes + @as(usize, if (mode == .close_oversize) 1 else 0);
                    try writer.interface.writeAll(("x" ** (http.max_response_bytes + 1))[0..length]);
                },
                .close_delimited => {
                    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nok");
                },
                .oversized_chunk, .chunk_limit => {
                    const length = http.max_response_bytes + @as(usize, if (mode == .oversized_chunk) 1 else 0);
                    try writer.interface.print("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n{x}\r\n", .{length});
                    try writer.interface.writeAll(("x" ** (http.max_response_bytes + 1))[0..length]);
                    try writer.interface.writeAll("\r\n0\r\n\r\n");
                },
                .truncated => {
                    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nx");
                },
                .headers, .headers_limit, .header_bytes => {
                    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n");
                    for (0..@as(usize, if (mode == .headers_limit) 63 else 70)) |i| try writer.interface.print("X-{d}: {s}\r\n", .{ i, if (mode == .header_bytes) "x" ** 160 else "value" });
                    try writer.interface.writeAll("\r\nok");
                },
                .utf8 => try request.respond("a\xff\x00b", .{ .keep_alive = false, .extra_headers = &.{.{ .name = "X-Bytes", .value = "a\xffb" }} }),
                .malformed => {
                    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nBad Header: value\r\n\r\nx");
                },
                .compressed => try request.respond("bad", .{ .keep_alive = false, .extra_headers = &.{.{ .name = "Content-Encoding", .value = "gzip" }} }),
                // One event, then a wait for the test, then a character split across two writes, a stray byte, and the end.
                .sse => {
                    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\nb\r\ndata: one\n\n\r\n");
                    try writer.interface.flush();
                    self.announce();
                    try self.pause();
                    try writer.interface.writeAll("8\r\ndata: \xe4\xb8\r\n");
                    try writer.interface.flush();
                    // The stray byte at the end arrives repaired, after the last whole character.
                    try writer.interface.writeAll("9\r\n\x96\xe7\x95\x8c\n\ndat\r\n8\r\na: end\n\xff\r\n0\r\n\r\n");
                },
            }
            try writer.interface.flush();
            switch (mode) {
                .stall, .upload_stall, .partial_head, .empty, .redirect, .slow_body => {
                    self.announce();
                    try self.pause();
                },
                else => {},
            }
            return;
        }
    }

    fn announce(self: *Peer) void {
        self.ready.set(self.io);
        if (self.wake) |wake| wake.set(self.io);
    }
};
