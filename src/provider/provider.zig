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
pub const http_transport = @import("transport/http.zig");

/// Serialize a provider request body for `protocol`. The result uses `arena` storage.
/// The function uses `request.model` as the upstream model. A null `target` drops reasoning replay.
pub fn requestBody(
    arena: std.mem.Allocator,
    messages: []const wire.message.Message,
    protocol: wire.enums.ProviderProtocol,
    request: ir.Request,
    target: ?wire.message.TurnProvenance,
) ![]const u8 {
    const request_ir = try build.build(arena, messages, .{ .target = target });
    var body: std.Io.Writer.Allocating = .init(arena);
    switch (protocol) {
        .@"anthropic-messages" => try request_anthropic.serialize(&body.writer, request, request_ir, .{}),
        .@"openai-completions" => try request_openai_chat.serialize(&body.writer, request, request_ir, .{}),
        .@"openai-responses" => try request_openai_responses.serialize(&body.writer, request, request_ir, .{}),
    }
    return body.written();
}

test {
    std.testing.refAllDecls(@This());
}
