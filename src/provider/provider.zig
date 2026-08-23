//! The provider layer exposes SSE framing, neutral events, and provider reducers.

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

pub const transport = @import("transport.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
