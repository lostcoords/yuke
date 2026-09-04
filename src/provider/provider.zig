//! The yuke provider layer adapts the independent AI module to the wire protocol.

const std = @import("std");
const proto = @import("proto");
pub const ai = @import("ai");

pub const event = ai.event;

pub const ir = ai.ir;
pub const build = @import("request/build.zig");

pub const model = ai.model;
pub const instance = ai.instance;
pub const resolve = ai.resolve;
pub const config = @import("config/providers.zig");

pub const oauth = @import("oauth/oauth.zig");
pub const oauth_xai = @import("oauth/xai.zig");
pub const oauth_codex = @import("oauth/codex.zig");
pub const transport = ai.transport;
pub const http_transport = ai.http_transport;
pub const failure = @import("failure.zig");
pub const retry = ai.retry;

/// Return the protocol's request serializer and stream reducer.
pub const Adapter = ai.Adapter;

/// Serialize a provider request body for `protocol`. The result uses `arena` storage.
/// The function uses `request.model` as the upstream model. A null `target` drops reasoning replay.
pub fn requestBody(
    arena: std.mem.Allocator,
    messages: []const proto.message.Message,
    protocol: ai.Protocol,
    request: ir.Request,
    target: ?proto.message.TurnProvenance,
    modalities: ai.model.Modalities,
) ![]u8 {
    const identity: ?ai.ModelIdentity = if (target) |value| .{
        .protocol = protocolFromProto(value.protocol),
        .model = value.model,
    } else null;
    const request_ir = try build.build(arena, messages, .{ .target = identity, .modalities = modalities });
    return ai.requestBody(arena, protocol, request, request_ir);
}

pub fn protocolFromProto(protocol: proto.enums.ProviderProtocol) ai.Protocol {
    return switch (protocol) {
        .anthropic_messages => .anthropic_messages,
        .openai_chat => .openai_chat,
        .openai_responses => .openai_responses,
    };
}

pub fn protocolToProto(protocol: ai.Protocol) proto.enums.ProviderProtocol {
    return switch (protocol) {
        .anthropic_messages => .anthropic_messages,
        .openai_chat => .openai_chat,
        .openai_responses => .openai_responses,
    };
}

pub fn finishReasonToProto(reason: ai.FinishReason) proto.enums.StopReason {
    return switch (reason) {
        .stop => .stop,
        .length => .length,
        .content_filter => .content_filter,
        .refusal => .refusal,
        .tool_calls => .tool_calls,
        .unknown => .unknown,
    };
}

pub fn usageToProto(usage: ai.Usage) proto.message.TokenUsage {
    return .{
        .input = usage.input,
        .output = usage.output,
        .reasoning = usage.reasoning,
        .cache_read = usage.cache_read,
        .cache_write = usage.cache_write,
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "every AI protocol maps to the yuke wire and back" {
    inline for (std.meta.tags(ai.Protocol)) |protocol| {
        try std.testing.expectEqual(protocol, protocolFromProto(protocolToProto(protocol)));
    }
}
