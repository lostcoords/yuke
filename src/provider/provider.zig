//! The provider layer exposes SSE framing, neutral events, and provider reducers.

const std = @import("std");
const proto = @import("proto");

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

pub const model = @import("model.zig");
pub const instance = @import("instance/instance.zig");
pub const resolve = @import("instance/resolve.zig");
pub const config = @import("config/providers.zig");

pub const oauth = @import("oauth/oauth.zig");
pub const oauth_xai = @import("oauth/xai.zig");
pub const oauth_codex = @import("oauth/codex.zig");
pub const transport = @import("transport.zig");
pub const http_transport = @import("transport/http.zig");
pub const failure = @import("failure.zig");
pub const retry = @import("retry.zig");

/// Return the protocol's request serializer and stream reducer. A new protocol needs one arm here.
pub fn Adapter(comptime protocol: proto.enums.ProviderProtocol) type {
    return switch (protocol) {
        .anthropic_messages => struct {
            pub const serialize = request_anthropic.serialize;
            pub const Reducer = anthropic.Reducer;
        },
        .openai_chat => struct {
            pub const serialize = request_openai_chat.serialize;
            pub const Reducer = openai_chat.Reducer;
        },
        .openai_responses => struct {
            pub const serialize = request_openai_responses.serialize;
            pub const Reducer = openai_responses.Reducer;
        },
    };
}

/// Serialize a provider request body for `protocol`. The result uses `arena` storage.
/// The function uses `request.model` as the upstream model. A null `target` drops reasoning replay.
pub fn requestBody(
    arena: std.mem.Allocator,
    messages: []const proto.message.Message,
    protocol: proto.enums.ProviderProtocol,
    request: ir.Request,
    target: ?proto.message.TurnProvenance,
) ![]u8 {
    const request_ir = try build.build(arena, messages, .{ .target = target });
    var body: std.Io.Writer.Allocating = .init(arena);
    switch (protocol) {
        inline else => |p| try Adapter(p).serialize(&body.writer, request, request_ir),
    }
    return body.written();
}

test {
    std.testing.refAllDecls(@This());
}
