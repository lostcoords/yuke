//! A transport opens one provider response and hands its body to a `Stream`.

const std = @import("std");
const http = @import("transport/http.zig");
const route = @import("route.zig");
const types = @import("types.zig");

pub const HttpTransport = http.HttpTransport;
pub const HttpError = http.Error;

pub const Request = route.Request;

/// What one attempt learned. The adapter fills it; the retry classifier reads it after a failure.
pub const AttemptInfo = struct {
    /// A parsed `retry-after-ms`, or `retry-after` converted to milliseconds.
    retry_after_ms: ?u64 = null,
    /// The provider sent `x-should-retry: false`, which vetoes a retry.
    no_retry: bool = false,
    /// The adapter sets this before the first body write. A later transport fault is then ambiguous.
    delivery: Delivery = .definitely_unsent,
    /// The status of a non-200 answer; a 200 stream that fails later leaves it null.
    status: ?u16 = null,
    /// The provider request id from `request-id` or `x-request-id`, when the answer names one.
    request_id: ?[]const u8 = null,
    /// The first bytes of the error answer, at most `max_error_body_bytes`: a non-200 body, or the stream event that failed a 200 response.
    body: ?[]const u8 = null,

    pub const Delivery = enum { definitely_unsent, possibly_sent };
    pub const max_error_body_bytes: usize = 4096;
};

/// Open one provider response through an injected transport, whose body borrows `arena`.
pub const Transport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, request: Request, info: *AttemptInfo) anyerror!ResponseBody,
    };

    pub fn open(self: Transport, arena: std.mem.Allocator, request: Request, info: *AttemptInfo) anyerror!ResponseBody {
        return self.vtable.open(self.ctx, arena, request, info);
    }
};

/// One provider response. A blocking adapter uses cancelable `std.Io` and returns `error.Canceled`.
pub const ResponseBody = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Return the bytes the response holds now, or an empty slice at the end of the stream.
        peek: *const fn (ctx: *anyopaque) anyerror![]const u8,
        /// Drop the first `count` bytes of the last peek, which stay readable until the next peek.
        toss: *const fn (ctx: *anyopaque, count: usize) void,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn peek(self: ResponseBody) anyerror![]const u8 {
        return self.vtable.peek(self.ctx);
    }
    pub fn toss(self: ResponseBody, count: usize) void {
        self.vtable.toss(self.ctx, count);
    }
    pub fn deinit(self: ResponseBody) void {
        self.vtable.deinit(self.ctx);
    }
};
