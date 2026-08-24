//! The provider layer exposes SSE framing, neutral events, and provider reducers.

const std = @import("std");
const wire = @import("wire");

pub const sse = @import("stream/sse.zig");
pub const event = @import("stream/event.zig");
pub const anthropic = @import("stream/anthropic.zig");
pub const openai_chat = @import("stream/openai_chat.zig");
pub const openai_responses = @import("stream/openai_responses.zig");

pub const ir = @import("request/ir.zig");
pub const build = @import("request/build.zig");
pub const request_anthropic = @import("request/anthropic.zig");
pub const request_openai_chat = @import("request/openai_chat.zig");
pub const request_openai_responses = @import("request/openai_responses.zig");

pub const instance = @import("instance/instance.zig");
pub const resolve = @import("instance/resolve.zig");
pub const config = @import("config/providers.zig");

pub const transport = @import("transport.zig");

/// Serialize a provider request body from messages. A user turn and an internal model call use this function.
/// The bytes use the allocator's storage, so pass an arena. The function supports the Anthropic protocol only.
pub fn requestBody(arena: std.mem.Allocator, messages: []const wire.message.Message, request: ir.Request) ![]const u8 {
    const request_ir = try build.build(arena, messages, .{});
    var body: std.Io.Writer.Allocating = .init(arena);
    try request_anthropic.serialize(&body.writer, request, request_ir, .{});
    return body.written();
}

test {
    std.testing.refAllDecls(@This());
}
