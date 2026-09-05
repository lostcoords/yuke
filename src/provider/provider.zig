//! The yuke provider layer adapts the independent AI module to the wire protocol.

const std = @import("std");
const proto = @import("proto");
const ai = @import("ai");

pub const request_builder = @import("request_builder.zig");

pub const config = @import("config/providers.zig");

pub const oauth = @import("oauth/oauth.zig");
pub const oauth_xai = @import("oauth/xai.zig");
pub const oauth_codex = @import("oauth/codex.zig");
pub const failure = @import("failure.zig");

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
