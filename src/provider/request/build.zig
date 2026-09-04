//! Fold a transcript into the neutral block IR that all serializers share.

const std = @import("std");
const proto = @import("proto");
const provider = @import("../provider.zig");
const ai = @import("ai");
const ir = ai.ir;
const types = ai.types;

const Block = ir.Block;

pub const Options = struct {
    target: ?types.ModelIdentity = null,
    modalities: types.Modalities = .{},
};

/// A bad transcript degrades the turn; the engine never crashes on stored data.
pub const Error = error{ OutOfMemory, InvalidTranscript, UnresolvedBlob };

/// Build the block IR in `gpa`. Blocks borrow transcript strings.
pub fn build(gpa: std.mem.Allocator, messages: []const proto.message.Message, options: Options) Error!ir.RequestIr {
    var blocks: std.ArrayList(Block) = .empty;
    errdefer blocks.deinit(gpa);

    for (messages) |message| switch (message) {
        .user => |user| for (user.content) |part| {
            if (part == .text and part.text.text.len == 0) continue; // Skip empty user text, as the assistant fold does.
            try blocks.append(gpa, .{ .role = .user, .value = try userValue(part, options) });
        },
        .assistant => |assistant| try foldAssistant(gpa, &blocks, assistant, options),
        .compaction => |compaction| if (compaction.summary.len != 0) {
            try blocks.append(gpa, .{ .role = .user, .value = .{ .text = compaction.summary } });
        },
    };

    // A serializer needs at least one block. An empty transcript is a bad turn, not a crash.
    if (blocks.items.len == 0) return error.InvalidTranscript;
    return .{ .blocks = try blocks.toOwnedSlice(gpa) };
}

/// Map one user part from its media type, because the part name does not classify a file.
fn userValue(part: proto.content.ContentPart, options: Options) Error!Block.Value {
    return switch (part) {
        .text => |t| .{ .text = t.text },
        .image => |t| mediaValue(t.source, options),
        .audio => |t| mediaValue(t.source, options),
        .file => |t| mediaValue(t.source, options),
    };
}

/// Map one attachment against the target model, and give a note for a kind it cannot read.
fn mediaValue(source: proto.content.MediaSource, options: Options) Error!Block.Value {
    const blob = source.blob;
    const kind = ir.modalityOf(blob.mime);
    // A model that lists nothing blocks nothing, so only a stated refusal replaces the attachment.
    if (options.modalities.takesInput(kind)) |takes| {
        if (!takes) return .{ .text = omittedNote(kind) };
    }
    // The model reads this kind, so the bytes must arrive. No blob store exists to read them yet.
    return error.UnresolvedBlob;
}

fn foldAssistant(gpa: std.mem.Allocator, blocks: *std.ArrayList(Block), msg: proto.message.AssistantMessage, options: Options) Error!void {
    const replay = if (options.target) |target| provenanceMatches(msg.provenance, target) else false;

    for (msg.content) |part| switch (part) {
        .text => |t| if (t.text.len != 0) try blocks.append(gpa, .{ .role = .assistant, .value = .{ .text = t.text } }),
        .reasoning => |t| if (replay) try blocks.append(gpa, .{ .role = .assistant, .value = .{ .reasoning = .{ .text = t.text, .signature = t.signature } } }),
        .redacted_reasoning => |t| if (replay) try blocks.append(gpa, .{ .role = .assistant, .value = .{ .redacted_reasoning = t.data } }),
        .tool => |t| {
            const call_id = t.call_id orelse return error.InvalidTranscript;
            try blocks.append(gpa, .{ .role = .assistant, .value = .{ .tool_use = .{
                .call_id = call_id,
                .name = t.name,
                .arguments = if (t.arguments.len == 0) "{}" else t.arguments,
            } } });
        },
    };

    // A tool result follows the assistant blocks, one per tool call.
    for (msg.content) |part| switch (part) {
        .tool => |t| {
            const call_id = t.call_id orelse return error.InvalidTranscript;
            const result = try terminalToolResult(t.state);
            try blocks.append(gpa, .{ .role = .user, .value = .{ .tool_result = .{
                .call_id = call_id,
                .content = result.content,
                .is_error = result.is_error,
            } } });
        },
        else => {},
    };
}

fn provenanceMatches(actual: ?proto.message.TurnProvenance, target: types.ModelIdentity) bool {
    const p = actual orelse return false;
    return provider.protocolFromProto(p.protocol) == target.protocol and std.mem.eql(u8, p.model, target.model);
}

fn omittedNote(kind: types.Modality) []const u8 {
    return switch (kind) {
        .image => "[image omitted: this model reads no images]",
        .audio => "[audio omitted: this model reads no audio]",
        .video => "[video omitted: this model reads no video]",
        .pdf => "[document omitted: this model reads no documents]",
        .text => unreachable,
    };
}

const ToolOutcome = struct { content: []const u8, is_error: bool };

fn terminalToolResult(state: proto.tool.ToolState) Error!ToolOutcome {
    return switch (state) {
        .completed => |c| .{ .content = c.output, .is_error = false },
        .@"error" => |e| .{ .content = e.@"error", .is_error = true },
        .canceled => .{ .content = "", .is_error = true },
        // A committed transcript holds only terminal tools.
        .pending, .running => error.InvalidTranscript,
    };
}

const testing = std.testing;

test "assistant tool call yields a tool_use then a tool_result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const content = [_]proto.message.AssistantPart{
        .{ .text = .{ .id = 1, .text = "let me check" } },
        .{ .tool = .{ .id = 2, .call_id = "call_1", .name = "run", .arguments = "{\"c\":1}", .state = .{ .completed = .{ .output = "ok", .duration_ms = 3 } } } },
    };
    const messages = [_]proto.message.Message{.{ .assistant = .{
        .id = 1,
        .run_id = 1,
        .config_rev = 1,
        .agent = "main",
        .content = &content,
        .time = .{ .created_at_ms = 0 },
    } }};

    const result = try build(arena.allocator(), &messages, .{});
    try testing.expectEqual(@as(usize, 3), result.blocks.len);
    try testing.expectEqualStrings("let me check", result.blocks[0].value.text);
    try testing.expectEqual(ir.Role.assistant, result.blocks[1].role);
    try testing.expectEqualStrings("call_1", result.blocks[1].value.tool_use.call_id);
    try testing.expectEqual(ir.Role.user, result.blocks[2].role);
    const tr = result.blocks[2].value.tool_result;
    try testing.expectEqualStrings("ok", tr.content);
    try testing.expect(!tr.is_error);
}

test "reasoning replays only when the provenance matches the target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const content = [_]proto.message.AssistantPart{
        .{ .reasoning = .{ .id = 1, .text = "ponder", .signature = "sig" } },
        .{ .text = .{ .id = 2, .text = "answer" } },
    };
    const messages = [_]proto.message.Message{.{ .assistant = .{
        .id = 1,
        .run_id = 1,
        .config_rev = 1,
        .agent = "main",
        .content = &content,
        .time = .{ .created_at_ms = 0 },
        .provenance = .{ .protocol = .anthropic_messages, .model = "claude" },
    } }};

    const dropped = try build(arena.allocator(), &messages, .{});
    try testing.expectEqual(@as(usize, 1), dropped.blocks.len); // A null target drops reasoning.

    const kept = try build(arena.allocator(), &messages, .{ .target = .{ .protocol = .anthropic_messages, .model = "claude" } });
    try testing.expectEqual(@as(usize, 2), kept.blocks.len);
    try testing.expectEqualStrings("ponder", kept.blocks[0].value.reasoning.text);

    const mismatch = try build(arena.allocator(), &messages, .{ .target = .{ .protocol = .anthropic_messages, .model = "other" } });
    try testing.expectEqual(@as(usize, 1), mismatch.blocks.len);
}

test "a model that reads no images sees a note where the attachment was" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blob: proto.content.MediaBlob = .{ .hash = std.mem.zeroes([64]u8), .mime = "image/png", .bytes = 2 };
    const parts = [_]proto.content.ContentPart{
        .{ .text = .{ .text = "look" } },
        .{ .image = .{ .source = .{ .blob = blob } } },
    };
    const messages = [_]proto.message.Message{.{ .user = .{
        .id = 1,
        .content = &parts,
        .input_id = 2,
        .time = .{ .created_at_ms = 0 },
    } }};

    // A session that switches to a text-only model must still work on every later turn.
    const text_only = try build(arena.allocator(), &messages, .{ .modalities = .{ .input = &.{.text} } });
    try testing.expectEqual(@as(usize, 2), text_only.blocks.len);
    try testing.expectEqualStrings("look", text_only.blocks[0].value.text);
    try testing.expectEqualStrings("[image omitted: this model reads no images]", text_only.blocks[1].value.text);

    // A model that reads images must receive the bytes, so the missing store is an error and never a note.
    try testing.expectError(
        error.UnresolvedBlob,
        build(arena.allocator(), &messages, .{ .modalities = .{ .input = &.{ .text, .image } } }),
    );

    // A model that lists nothing states no refusal, so the attachment is still owed its bytes.
    try testing.expectError(error.UnresolvedBlob, build(arena.allocator(), &messages, .{}));
}

test "the media type selects the omitted-attachment note" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const reads_images: Options = .{ .modalities = .{ .input = &.{ .text, .image } } };

    inline for (.{
        .{ "application/pdf", "[document omitted: this model reads no documents]" },
        .{ "audio/mpeg", "[audio omitted: this model reads no audio]" },
        .{ "video/mp4", "[video omitted: this model reads no video]" },
    }) |case| {
        const blob: proto.content.MediaBlob = .{ .hash = std.mem.zeroes([64]u8), .mime = case[0], .bytes = 2 };
        const parts = [_]proto.content.ContentPart{.{ .file = .{ .source = .{ .blob = blob } } }};
        const messages = [_]proto.message.Message{.{ .user = .{
            .id = 1,
            .content = &parts,
            .input_id = 2,
            .time = .{ .created_at_ms = 0 },
        } }};
        const folded = try build(arena.allocator(), &messages, reads_images);
        try testing.expectEqualStrings(case[1], folded.blocks[0].value.text);
    }
}
