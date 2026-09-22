//! A loopback MCP peer over HTTP: modern Streamable HTTP, legacy Streamable HTTP with a session, and the old HTTP+SSE transport.

const std = @import("std");

const session_id = "s-1";
const legacy_version = "2025-06-18";

/// Messages one task writes onto another task's open event stream.
const Channel = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Event = .unset,
    items: std.ArrayList([]u8) = .empty,

    fn push(self: *Channel, peer: *Peer, message: []const u8) !void {
        const owned = try peer.gpa.dupe(u8, message);
        errdefer peer.gpa.free(owned);
        try self.mutex.lock(peer.io);
        defer self.mutex.unlock(peer.io);
        try self.items.append(peer.gpa, owned);
        self.ready.set(peer.io);
    }

    /// Write every queued message as one event, then wait for more until the task ends.
    fn drain(self: *Channel, peer: *Peer, writer: *std.Io.Writer) !void {
        while (true) {
            self.ready.reset();
            try self.mutex.lock(peer.io);
            const taken = self.items.toOwnedSlice(peer.gpa) catch unreachable;
            self.mutex.unlock(peer.io);
            defer {
                for (taken) |item| peer.gpa.free(item);
                peer.gpa.free(taken);
            }
            for (taken) |item| try writer.print("event: message\ndata: {s}\n\n", .{item});
            try writer.flush();
            try self.ready.wait(peer.io);
        }
    }

    fn deinit(self: *Channel, gpa: std.mem.Allocator) void {
        for (self.items.items) |item| gpa.free(item);
        self.items.deinit(gpa);
    }
};

pub const Peer = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    base: []u8,
    tasks: std.Io.Group = .init,
    wake: ?*std.Io.Event = null,
    /// The legacy GET stream and the old transport's stream.
    pushes: Channel = .{},
    events: Channel = .{},
    changed: std.atomic.Value(bool) = .init(false),
    /// The modern slow call saw its stream close.
    cancel_seen: std.Io.Event = .unset,
    deleted: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    pub fn create(gpa: std.mem.Allocator, io: std.Io) !*Peer {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var server = try address.listen(io, .{});
        errdefer server.deinit(io);
        const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
        errdefer gpa.free(base);
        const self = try gpa.create(Peer);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .server = server, .base = base };
        try self.tasks.concurrent(io, accept, .{self});
        return self;
    }

    pub fn destroy(self: *Peer) void {
        self.tasks.cancel(self.io);
        self.pushes.deinit(self.gpa);
        self.events.deinit(self.gpa);
        self.server.deinit(self.io);
        self.gpa.free(self.base);
        self.gpa.destroy(self);
    }

    fn accept(self: *Peer) void {
        while (true) {
            const stream = self.server.accept(self.io) catch return;
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
        if (self.wake) |wake| wake.set(self.io);
    }

    fn exchange(self: *Peer, stream: std.Io.net.Stream) !void {
        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var reader = stream.reader(self.io, &read_buf);
        var writer = stream.writer(self.io, &write_buf);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        const target = request.head.target;
        const out = &writer.interface;
        if (!std.mem.eql(u8, header(&request, "x-token") orelse "", "secret")) return plain(out, "401 Unauthorized", "unauthorized");

        if (request.head.method == .GET) {
            if (std.mem.eql(u8, target, "/sse")) {
                try streamHead(out);
                try out.writeAll("event: endpoint\ndata: /sse/messages?session=1\n\n");
                try out.flush();
                return self.events.drain(self, out);
            }
            if (std.mem.eql(u8, target, "/legacy")) {
                if (!legacyHeaders(&request)) return plain(out, "400 Bad Request", "no session");
                try streamHead(out);
                return self.pushes.drain(self, out);
            }
            return plain(out, "405 Method Not Allowed", "");
        }
        if (request.head.method == .DELETE) {
            if (std.mem.eql(u8, header(&request, "mcp-session-id") orelse "", session_id)) self.deleted.store(true, .release);
            return plain(out, "200 OK", "");
        }

        // The body reader invalidates the head, so the checked headers are copied first.
        var copies: [4][128]u8 = undefined;
        const version = copy(&copies[0], header(&request, "mcp-protocol-version"));
        const routed_method = copy(&copies[1], header(&request, "mcp-method"));
        const routed_name = copy(&copies[2], header(&request, "mcp-name"));
        const session = copy(&copies[3], header(&request, "mcp-session-id"));
        const legacy = std.mem.eql(u8, session, session_id) and std.mem.eql(u8, version, legacy_version);
        var body_buf: [1024]u8 = undefined;
        const body = try request.readerExpectNone(&body_buf).allocRemaining(self.gpa, .limited(64 * 1024));
        defer self.gpa.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, body, .{});
        defer parsed.deinit();
        const message = parsed.value.object;
        const method = if (message.get("method")) |value| value.string else "";
        const id = if (message.get("id")) |value| value.integer else null;
        const params = if (message.get("params")) |value| value.object else null;
        const name = if (params) |p| if (p.get("name")) |value| value.string else "" else "";
        const text = text: {
            const p = params orelse break :text "";
            const arguments = p.get("arguments") orelse break :text "";
            const value = arguments.object.get("text") orelse break :text "";
            break :text value.string;
        };

        if (std.mem.eql(u8, target, "/modern")) {
            // The body and the header name the same version, and the routing headers match the body.
            if (!std.mem.eql(u8, version, "2026-07-28")) return plain(out, "400 Bad Request", "version");
            if (!std.mem.eql(u8, routed_method, method)) return plain(out, "400 Bad Request", "method");
            if (std.mem.eql(u8, method, "tools/call") and !std.mem.eql(u8, routed_name, name)) return plain(out, "400 Bad Request", "name");
            const reply_id = id orelse return plain(out, "202 Accepted", "");
            if (std.mem.eql(u8, method, "server/discover")) {
                return json(out, "", "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{{\"tools\":{{}}}}}}}}", .{reply_id});
            }
            try streamHead(out);
            if (std.mem.eql(u8, method, "tools/list")) {
                try out.print(": keepalive\n\nevent: message\ndata: {{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"echo\",\"inputSchema\":{{\"type\":\"object\"}}}},{{\"name\":\"slow\",\"inputSchema\":{{\"type\":\"object\"}}}}]}}}}\n\n", .{reply_id});
                return out.flush();
            }
            if (std.mem.eql(u8, name, "slow")) {
                try out.writeAll(": working\n\n");
                try out.flush();
                // The client closes the stream to cancel, so the next read ends.
                _ = server.receiveHead() catch {};
                self.cancel_seen.set(self.io);
                return;
            }
            // A progress notification may precede the answer on the same stream.
            try out.print("event: message\ndata: {{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{{\"progressToken\":1,\"progress\":1}}}}\n\n", .{});
            try out.print("event: message\ndata: {{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"content\":[{{\"type\":\"text\",\"text\":\"modern http: {s}\"}}]}}}}\n\n", .{ reply_id, text });
            return out.flush();
        }

        if (std.mem.eql(u8, target, "/legacy")) {
            if (std.mem.eql(u8, method, "initialize")) {
                return json(out, session_id, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"protocolVersion\":\"" ++ legacy_version ++ "\",\"capabilities\":{{\"tools\":{{\"listChanged\":true}}}},\"serverInfo\":{{\"name\":\"legacy\",\"version\":\"1\"}}}}}}", .{id.?});
            }
            // A legacy server refuses a request outside its session, so the modern probe fails here.
            if (!legacy) return plain(out, "400 Bad Request", "Bad Request: Server not initialized");
            const reply_id = id orelse return plain(out, "202 Accepted", "");
            if (std.mem.eql(u8, method, "tools/list")) {
                const tools = if (self.changed.load(.acquire)) "{\"name\":\"added\",\"inputSchema\":{\"type\":\"object\"}},{\"name\":\"echo\",\"inputSchema\":{\"type\":\"object\"}}" else "{\"name\":\"echo\",\"inputSchema\":{\"type\":\"object\"}}";
                return json(out, "", "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tools\":[{s}]}}}}", .{ reply_id, tools });
            }
            if (std.mem.eql(u8, text, "change")) {
                self.changed.store(true, .release);
                try self.pushes.push(self, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}");
            }
            return json(out, "", "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"legacy http: {s}\"}}]}}}}", .{ reply_id, text });
        }

        if (std.mem.startsWith(u8, target, "/sse/messages")) {
            // Every answer rides the event stream; the POST only accepts the message.
            if (id) |reply_id| {
                var reply: std.Io.Writer.Allocating = .init(self.gpa);
                defer reply.deinit();
                if (std.mem.eql(u8, method, "initialize")) {
                    try reply.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"old\",\"version\":\"1\"}}}}}}", .{reply_id});
                } else if (std.mem.eql(u8, method, "tools/list")) {
                    try reply.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tools\":[{{\"name\":\"echo\",\"inputSchema\":{{\"type\":\"object\"}}}}]}}}}", .{reply_id});
                } else if (std.mem.eql(u8, method, "tools/call")) {
                    try reply.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"old sse: {s}\"}}]}}}}", .{ reply_id, text });
                } else {
                    try reply.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}", .{reply_id});
                }
                try self.events.push(self, reply.written());
            }
            return plain(out, "202 Accepted", "");
        }
        return plain(out, "404 Not Found", "");
    }

    /// A legacy request after `initialize` names the session and the negotiated version.
    fn legacyHeaders(request: *std.http.Server.Request) bool {
        return std.mem.eql(u8, header(request, "mcp-session-id") orelse "", session_id) and
            std.mem.eql(u8, header(request, "mcp-protocol-version") orelse "", legacy_version);
    }
};

fn header(request: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

fn copy(buf: *[128]u8, value: ?[]const u8) []const u8 {
    const text = value orelse return "";
    const len = @min(text.len, buf.len);
    @memcpy(buf[0..len], text[0..len]);
    return buf[0..len];
}

fn plain(out: *std.Io.Writer, status: []const u8, body: []const u8) !void {
    try out.print("HTTP/1.1 {s}\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, body.len, body });
    try out.flush();
}

fn json(out: *std.Io.Writer, session: []const u8, comptime format: []const u8, args: anytype) !void {
    var buf: [2048]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, format, args);
    try out.print("HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n", .{body.len});
    if (session.len != 0) try out.print("Mcp-Session-Id: {s}\r\n", .{session});
    try out.print("\r\n{s}", .{body});
    try out.flush();
}

/// An event stream has no length; the peer ends it by closing the connection.
fn streamHead(out: *std.Io.Writer) !void {
    try out.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n");
    try out.flush();
}
