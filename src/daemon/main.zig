//! The yuke daemon entry point.

const std = @import("std");
const zio = @import("zio");
const http = @import("http.zig");

// zio.debug_io breaks the WebSocket upgrade path in zio v0.16.0. std.log uses the default.

// The default front-door port. A TLS-terminating proxy sits in front for the web path.
const default_port = 7880;

pub fn main(init: std.process.Init) !void {
    // One executor owns all daemon state. The daemon needs no locks.
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .exact(1) });
    defer rt.deinit();

    const address = try zio.net.IpAddress.parseIp4("127.0.0.1", default_port);
    try http.serve(init.gpa, address);
}
