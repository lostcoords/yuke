//! Estimate the model tokens of committed messages from the parts that a request sends.

const std = @import("std");
const proto = @import("proto");
const request_builder = @import("../provider/request_builder.zig");

/// One image or attachment costs about this many tokens after a provider resize, whatever its byte size.
pub const media_tokens: u64 = 1600;
/// The request wraps a summary in a fixed frame of instruction text.
const summary_frame_tokens: u64 = 128;
/// Encrypted reasoning holds base64 ciphertext. Its decoded size minus this frame approximates the trace.
const encrypted_frame_bytes: u64 = 650;

/// The estimate of one message. `reasoning` is the share of `tokens` that only a request to the same model replays.
pub const Estimate = struct { tokens: u64, reasoning: u64 };

/// Charge four bytes as one token. A provider count replaces this estimate where one exists.
pub fn ofBytes(bytes: u64) u64 {
    return bytes / 4 + @intFromBool(bytes % 4 != 0);
}

/// Charge one summary and its request frame.
pub fn ofSummary(summary: []const u8) u64 {
    return ofBytes(summary.len) + summary_frame_tokens;
}

/// Estimate one committed message from the parts that the request builder sends. Envelope fields and views cost nothing.
pub fn ofMessage(message: proto.message.Message) Estimate {
    return switch (message) {
        .user => |u| .{ .tokens = ofUser(u), .reasoning = 0 },
        .assistant => |a| ofAssistant(a),
        .compaction => |c| .{ .tokens = ofSummary(c.summary), .reasoning = 0 },
    };
}

fn ofUser(user: proto.message.UserMessage) u64 {
    var bytes: u64 = 0;
    var media: u64 = 0;
    for (user.content) |part| switch (part) {
        .text => |t| bytes += t.text.len,
        .image, .audio, .file => media += 1,
    };
    return ofBytes(bytes) + media * media_tokens;
}

fn ofAssistant(assistant: proto.message.AssistantMessage) Estimate {
    var bytes: u64 = 0;
    var reasoning: u64 = 0;
    var media: u64 = 0;
    for (assistant.content) |part| switch (part) {
        .text => |t| bytes += t.text.len,
        // Charge the larger of the summary text and the ciphertext at its decoded size.
        .reasoning => |r| reasoning += @max(r.text.len, encryptedBytes(r.signature.len)),
        .redacted_reasoning => |r| reasoning += encryptedBytes(r.data.len),
        .tool => |t| {
            // The call and its result both name the call id.
            bytes += t.name.len + t.arguments.len + 2 * t.call_id.len;
            switch (t.state) {
                .completed => |c| {
                    bytes += c.output.len;
                    if (c.media) |blobs| media += blobs.len;
                    // A loaded definition enters the request as a declared tool.
                    if (c.tools_added) |definitions| for (definitions) |d| {
                        bytes += d.name.len + d.description.len + d.input_schema.len;
                    };
                },
                .@"error" => |e| bytes += e.@"error".len,
                .canceled => bytes += request_builder.canceled_tool_note.len,
                // A committed message has no open call.
                .pending, .running => {},
            }
        },
    };
    // A failed or canceled run adds one user block after its tool results.
    if (assistant.@"error") |e| bytes += e.type.len + e.message.len + if (e.detail) |d| d.len else 0;
    if (assistant.finish == .canceled) bytes += request_builder.interrupted_marker.len;
    const replayed = ofBytes(reasoning);
    return .{ .tokens = ofBytes(bytes) + replayed + media * media_tokens, .reasoning = replayed };
}

fn encryptedBytes(base64_bytes: u64) u64 {
    return (base64_bytes / 4 * 3) -| encrypted_frame_bytes;
}

const testing = std.testing;

test "the estimate charges request text, decoded ciphertext, and media, and not the stored envelope" {
    const blob: proto.content.MediaBlob = .{ .hash = .bytes(@splat(0x5a)), .mime = "image/png", .bytes = 64 };
    const message: proto.message.Message = .{ .assistant = .{
        .id = 1,
        .run_id = 1,
        .config_rev = 0,
        .time = .{ .created_at_ms = 1 },
        .finish = .canceled,
        .content = &.{
            .{ .text = .{ .id = 0, .text = "t" ** 400 } },
            .{ .reasoning = .{ .id = 1, .text = "short summary", .signature = "A" ** 4000, .title = "" } },
            .{ .tool = .{ .id = 2, .call_id = "call_1", .name = "read", .arguments = "a" ** 96, .state = .{ .completed = .{
                .output = "o" ** 1000,
                .view = &.{},
                .media = &.{blob},
                .duration_ms = 1,
            } } } },
            .{ .tool = .{ .id = 3, .call_id = "call_2", .name = "exec", .arguments = "{}", .state = .{ .canceled = .{} } } },
        },
    } };
    // The ciphertext decodes to 3000 bytes less its 650-byte frame, and only the same model replays it.
    const reasoning = ofBytes(3000 - 650);
    const sent = 400 + (4 + 96 + 2 * 6 + 1000) + (4 + 2 + 2 * 6 + request_builder.canceled_tool_note.len) + request_builder.interrupted_marker.len;
    try testing.expectEqual(Estimate{ .tokens = ofBytes(sent) + reasoning + media_tokens, .reasoning = reasoning }, ofMessage(message));
    // A summary longer than the decoded ciphertext wins, as a plain Anthropic trace does.
    const plain: proto.message.Message = .{ .assistant = .{ .id = 2, .run_id = 1, .config_rev = 0, .time = .{ .created_at_ms = 2 }, .content = &.{
        .{ .reasoning = .{ .id = 0, .text = "r" ** 800, .signature = "sig", .title = "" } },
    } } };
    try testing.expectEqual(ofBytes(800), ofMessage(plain).reasoning);
}
