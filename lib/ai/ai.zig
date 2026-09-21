//! Provider-neutral model calls over three closed wire protocols.

const std = @import("std");
const call = @import("call.zig");
const types = @import("types.zig");

pub const Protocol = types.Protocol;
pub const FinishReason = types.FinishReason;
pub const Usage = types.Usage;
pub const Modality = types.Modality;
pub const Modalities = types.Modalities;
pub const MediaSource = types.MediaSource;
pub const ModelIdentity = types.ModelIdentity;
pub const limits = types.limits;

pub const Client = call.Client;
pub const Model = call.Model;
pub const Request = call.Request;
pub const Options = call.Options;
pub const Result = call.Result;
pub const Content = call.Content;
pub const PreparedRequest = call.PreparedRequest;
pub const prepare = call.prepare;
pub const consume = call.consume;
pub const generateWithTransport = call.generateWithTransport;
pub const generateTextWithTransport = call.generateTextWithTransport;
pub const streamWithTransport = call.streamWithTransport;

pub const Route = route.Route;
pub const Credential = route.Credential;
pub const Header = route.Header;

/// The request blocks, tools, and reasoning controls.
pub const ir = @import("request/ir.zig");
/// The neutral stream events one call emits.
pub const event = @import("stream/event.zig");
pub const tool_search = @import("tool_search.zig");
/// The model vocabulary every provider source shares.
pub const model = @import("model.zig");
/// How one request reaches a provider, and the credential headers it presents.
pub const route = @import("route.zig");
/// The baked provider table. It needs no network and no control-plane account.
pub const catalog = @import("catalog.zig");
/// The transport contract, and the HTTP transport that fulfils it.
pub const transport = @import("transport.zig");
pub const failure = @import("failure.zig");
pub const retry = @import("retry.zig");
/// Canned transports for a test.
pub const testing = @import("testing.zig");

test {
    std.testing.refAllDecls(@This());
}
