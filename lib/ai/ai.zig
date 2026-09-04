//! This AI module exposes provider-neutral calls for three closed wire protocols.

const std = @import("std");
const adapter = @import("adapter.zig");

pub const types = @import("types.zig");
pub const Protocol = types.Protocol;
pub const FinishReason = types.FinishReason;
pub const Usage = types.Usage;
pub const ModelIdentity = types.ModelIdentity;
pub const MediaSource = types.MediaSource;
pub const Provider = instance.ProviderInstance;
pub const Credential = resolve.Credential;

pub const sse = @import("stream/sse.zig");
pub const event = @import("stream/event.zig");
pub const anthropic = @import("stream/anthropic.zig");
pub const openai_chat = @import("stream/openai_chat.zig");
pub const openai_responses = @import("stream/openai_responses.zig");

pub const ir = @import("request/ir.zig");
pub const request_anthropic = @import("request/anthropic.zig");
pub const request_openai_chat = @import("request/openai_chat.zig");
pub const request_openai_responses = @import("request/openai_responses.zig");

pub const model = @import("model.zig");
/// The baked provider table. It needs no network and no control-plane account.
pub const catalog = @import("catalog.zig");
pub const instance = @import("instance/instance.zig");
pub const resolve = @import("instance/resolve.zig");
pub const failure = @import("failure.zig");
pub const retry = @import("retry.zig");
pub const transport = @import("transport.zig");
pub const http_transport = @import("transport/http.zig");
pub const call = @import("call.zig");
pub const Client = call.Client;
pub const Model = call.Model;
pub const Request = call.Request;
pub const Result = call.Result;
pub const Content = call.Content;
pub const TextOptions = call.TextOptions;
pub const Block = ir.Block;
pub const Tool = ir.Tool;
pub const OutputSchema = ir.OutputSchema;
pub const ReasoningControl = ir.ReasoningControl;
pub const generateWithTransport = call.generateWithTransport;
pub const generateTextWithTransport = call.generateTextWithTransport;
pub const streamWithTransport = call.streamWithTransport;

/// Return low-level protocol parts for an IR that has passed `ir.validate`.
pub fn Adapter(comptime protocol: Protocol) type {
    return adapter.Adapter(protocol);
}

/// Serialize one neutral request IR into the selected protocol body.
pub fn requestBody(arena: std.mem.Allocator, protocol: Protocol, request: ir.Request, request_ir: ir.RequestIr) ![]u8 {
    return adapter.serialize(arena, protocol, request, request_ir);
}

test {
    std.testing.refAllDecls(@This());
}
