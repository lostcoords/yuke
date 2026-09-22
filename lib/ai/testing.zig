//! Canned transports for tests. The real path uses `HttpTransport`.

const std = @import("std");
const AttemptInfo = @import("transport.zig").AttemptInfo;
const Request = @import("transport.zig").Request;
const ResponseBody = @import("transport.zig").ResponseBody;
const Transport = @import("transport.zig").Transport;

/// Replay canned bytes as one response body. A `chunk_size` of 0 fills the caller buffer.
pub const ReplayReader = struct {
    bytes: []const u8,
    chunk_size: usize = 0,
    offset: usize = 0,
    /// The read fails with this error after it delivers every byte.
    after: ?anyerror = null,

    pub fn body(self: *ReplayReader) ResponseBody {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: ResponseBody.VTable = .{ .peek = peek, .toss = toss, .deinit = deinitNoop };

    fn peek(ctx: *anyopaque) anyerror![]const u8 {
        const self: *ReplayReader = @ptrCast(@alignCast(ctx));
        const remaining = self.bytes[self.offset..];
        if (remaining.len == 0) return if (self.after) |err| err else "";
        if (self.chunk_size == 0) return remaining;
        return remaining[0..@min(self.chunk_size, remaining.len)];
    }
    fn toss(ctx: *anyopaque, count: usize) void {
        const self: *ReplayReader = @ptrCast(@alignCast(ctx));
        std.debug.assert(count <= self.bytes.len - self.offset); // A toss never passes the last peek.
        self.offset += count;
    }
    fn deinitNoop(_: *anyopaque) void {}
};

pub fn sseFrame(comptime json: []const u8) []const u8 {
    return "data: " ++ json ++ "\n\n";
}

/// One complete Anthropic text turn.
pub const canned_reply =
    sseFrame(
        \\{"type":"message_start","message":{"usage":{"input_tokens":0}}}
    ) ++ sseFrame(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    ) ++ sseFrame(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello from the yuke mock provider."}}
    ) ++ sseFrame(
        \\{"type":"content_block_stop","index":0}
    ) ++ sseFrame(
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":8}}
    ) ++ sseFrame(
        \\{"type":"message_stop"}
    );

/// Replay one fixed reply for every open.
pub const CannedTransport = struct {
    bytes: []const u8,

    pub fn transport(self: *CannedTransport) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Transport.VTable = .{ .open = open };

    /// Allocate a fresh reader in `arena`. Concurrent runs then share no offset state.
    fn open(ctx: *anyopaque, arena: std.mem.Allocator, request: Request, info: *AttemptInfo) anyerror!ResponseBody {
        _ = .{ request, info };
        const self: *CannedTransport = @ptrCast(@alignCast(ctx));
        const reader = try arena.create(ReplayReader);
        reader.* = .{ .bytes = self.bytes };
        return reader.body();
    }
};
