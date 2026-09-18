//! A local socket peer for host tests and benchmarks.

const std = @import("std");

pub const Peer = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    server: std.Io.net.Server,
    tasks: std.Io.Group = .init,
    mode: Mode,

    pub const Mode = enum { echo, stall, eof, json_lines };

    pub fn create(gpa: std.mem.Allocator, io: std.Io, mode: Mode) !*Peer {
        var random: [16]u8 = undefined;
        io.random(&random);
        const path = try std.fmt.allocPrint(gpa, "/tmp/yuke-net-{s}", .{std.fmt.bytesToHex(random, .lower)});
        errdefer gpa.free(path);
        const address = try std.Io.net.UnixAddress.init(path);
        var server = try address.listen(io, .{});
        errdefer server.deinit(io);
        errdefer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
        const self = try gpa.create(Peer);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .path = path, .server = server, .mode = mode };
        try self.tasks.concurrent(io, accept, .{self});
        return self;
    }

    pub fn destroy(self: *Peer) void {
        self.tasks.cancel(self.io);
        self.server.deinit(self.io);
        std.Io.Dir.deleteFileAbsolute(self.io, self.path) catch unreachable;
        self.gpa.free(self.path);
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
        switch (self.mode) {
            .stall => std.Io.sleep(self.io, .fromSeconds(60), .awake) catch {},
            .eof => {},
            .json_lines => {
                var reader = stream.reader(self.io, &.{});
                var writer = stream.writer(self.io, &.{});
                var request: [2]u8 = undefined;
                reader.interface.readSliceAll(&request) catch return;
                const responses = [_][]const u8{
                    "{\"text\":\"世😀\"}\n{\"ok\":true}\n",
                    "\"" ++ "a" ** 30 ++ "\"\n",
                    "\"" ++ "a" ** 31 ++ "\"\n",
                    "\"\xff\"\n",
                    "{]\n",
                    "{\"ok\":true}",
                    "\"\xf0\x9f",
                    "",
                };
                if (request[1] != '\n' or request[0] < '0' or request[0] >= '0' + responses.len) return;
                writer.interface.writeAll(responses[request[0] - '0']) catch return;
            },
            .echo => {
                var reader = stream.reader(self.io, &.{});
                var writer = stream.writer(self.io, &.{});
                var buffer: [4096]u8 = undefined;
                while (true) {
                    var slices = [_][]u8{&buffer};
                    const n = reader.interface.readVec(&slices) catch return;
                    writer.interface.writeAll(buffer[0..n]) catch return;
                }
            },
        }
    }
};
