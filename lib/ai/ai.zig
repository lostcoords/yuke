//! This AI module exposes provider-neutral calls for three closed wire protocols.

const std = @import("std");

pub const types = @import("types.zig");
pub const Protocol = types.Protocol;
pub const FinishReason = types.FinishReason;
pub const Usage = types.Usage;
pub const ModelIdentity = types.ModelIdentity;
pub const MediaSource = types.MediaSource;
pub const Route = instance.Route;
pub const Credential = resolve.Credential;

pub const event = @import("stream/event.zig");

pub const ir = @import("request/ir.zig");

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
pub const Options = call.Options;
pub const PreparedRequest = call.PreparedRequest;
pub const Result = call.Result;
pub const Content = call.Content;
pub const Block = ir.Block;
pub const Tool = ir.Tool;
pub const OutputSchema = ir.OutputSchema;
pub const ReasoningControl = ir.ReasoningControl;
pub const generateWithTransport = call.generateWithTransport;
pub const generateTextWithTransport = call.generateTextWithTransport;
pub const streamWithTransport = call.streamWithTransport;
pub const prepare = call.prepare;
pub const consume = call.consume;

test {
    std.testing.refAllDecls(@This());
}
