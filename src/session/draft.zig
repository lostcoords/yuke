//! Fold broadcast events in the engine and client. Copy bytes before `apply` returns.
//! Keep the Draft address stable. Let `gpa` own streamed buffers and `arena` own write-once data.

const std = @import("std");
const proto = @import("proto");

const ids = proto.ids;
const message = proto.message;
const tool = proto.tool;
const view = proto.view;
const activity = proto.activity;

/// The engine is the only producer, so an allocation failure is the one error a fold can return.
pub const Error = error{OutOfMemory};

/// Own the stream buffers and arena fields for one draft part.
pub const Part = union(enum) {
    text: Text,
    reasoning: Reasoning,
    redacted_reasoning: RedactedReasoning,
    tool: Tool,

    pub const Text = struct {
        id: ids.PartId,
        text: std.ArrayList(u8) = .empty,
    };
    pub const Reasoning = struct {
        id: ids.PartId,
        text: std.ArrayList(u8) = .empty,
        signature: []const u8,
    };
    pub const RedactedReasoning = struct {
        id: ids.PartId,
        data: []const u8,
    };
    pub const Tool = struct {
        id: ids.PartId,
        call_id: ?[]const u8 = null,
        name: []const u8,
        arguments: []const u8,
        input_view: ?[]const view.View = null,
        output: std.ArrayList(u8) = .empty,
        state: tool.ToolState,
    };

    /// Treat the protocol part id as the index in `Draft.parts`.
    pub fn id(self: *const Part) ids.PartId {
        return switch (self.*) {
            inline else => |p| p.id,
        };
    }

    /// Free the stream buffers that `gpa` owns.
    fn deinit(self: *Part, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .text => |*t| t.text.deinit(gpa),
            .reasoning => |*r| r.text.deinit(gpa),
            .redacted_reasoning => {},
            .tool => |*t| t.output.deinit(gpa),
        }
    }

    /// Build an owned part from a wire part. `gpa` backs stream buffers. `arena` backs write-once data.
    /// `deinit` frees the stream buffers. The caller keeps the arena.
    pub fn initFrom(gpa: std.mem.Allocator, arena: std.mem.Allocator, p: message.AssistantPart) Error!Part {
        switch (p) {
            .text => |t| {
                var text: std.ArrayList(u8) = .empty;
                try text.appendSlice(gpa, t.text);

                return .{ .text = .{ .id = t.id, .text = text } };
            },
            .reasoning => |r| {
                var text: std.ArrayList(u8) = .empty;
                try text.appendSlice(gpa, r.text);
                errdefer text.deinit(gpa);

                return .{ .reasoning = .{ .id = r.id, .text = text, .signature = try arena.dupe(u8, r.signature) } };
            },
            .redacted_reasoning => |r| return .{ .redacted_reasoning = .{
                .id = r.id,
                .data = try arena.dupe(u8, r.data),
            } },
            .tool => |t| {
                // Seed output from an active snapshot. A live part starts empty.
                var output: std.ArrayList(u8) = .empty;
                try output.appendSlice(gpa, toolOutputSeed(t.state));
                errdefer output.deinit(gpa);

                return .{ .tool = .{
                    .id = t.id,
                    .call_id = if (t.call_id) |c| try arena.dupe(u8, c) else null,
                    .name = try arena.dupe(u8, t.name),
                    .arguments = try arena.dupe(u8, t.arguments),
                    .input_view = if (t.input_view) |v| try proto.dupe(arena, v) else null,
                    .output = output,
                    .state = try dupeToolState(arena, t.state),
                } };
            },
        }
    }
};

/// Fold broadcast events into an active assistant message.
pub const Draft = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    message_id: ids.MessageId,
    run_id: ids.RunId,
    config_rev: ids.ConfigRev,
    agent: []const u8,
    created_at_ms: u64,
    parts: std.ArrayList(Part) = .empty,

    /// Open a draft from `message.started`. Clone the borrowed `agent` into the arena.
    pub fn init(gpa: std.mem.Allocator, d: message.MessageStartedData) Error!Draft {
        var self: Draft = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .message_id = d.message_id,
            .run_id = d.run_id,
            .config_rev = d.config_rev,
            .agent = "",
            .created_at_ms = d.created_at_ms,
        };
        self.agent = try self.arena.allocator().dupe(u8, d.agent);
        return self;
    }

    pub fn deinit(self: *Draft) void {
        for (self.parts.items) |*p| p.deinit(self.gpa);
        self.parts.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Append a part from `message.part_added`.
    /// Reject an out-of-order id when a part event is absent.
    pub fn addPart(self: *Draft, d: message.MessagePartAddedData) Error!void {
        return self.appendPart(d.part);
    }

    /// Clone a wire part. Check its ordinal and append it.
    fn appendPart(self: *Draft, p: message.AssistantPart) Error!void {
        const expected: ids.PartId = @intCast(self.parts.items.len);
        std.debug.assert(p.id() == expected); // the engine numbers each part in order
        var cloned = try Part.initFrom(self.gpa, self.arena.allocator(), p);
        errdefer cloned.deinit(self.gpa);
        try self.parts.append(self.gpa, cloned);
    }

    /// Fold a text or reasoning byte delta from `message.part_delta` into its buffer.
    pub fn applyPartDelta(self: *Draft, d: message.PartDelta) Error!void {
        const buf = self.streamBuffer(d.part_id);
        const cap: usize = @intCast(proto.meta.limits.max_message_string_bytes);
        return foldBytes(self.gpa, buf, d.offset, d.delta, cap);
    }

    /// Fold a `tool.output_delta` into the tool output buffer.
    pub fn applyToolOutputDelta(self: *Draft, d: message.PartDelta) Error!void {
        const t = self.toolPart(d.part_id);
        const cap: usize = @intCast(proto.meta.limits.max_tool_output_stream_bytes);
        return foldBytes(self.gpa, &t.output, d.offset, d.delta, cap);
    }

    /// Fold a `tool.state_changed` event.
    pub fn applyToolState(self: *Draft, d: tool.ToolStateChangedData) Error!void {
        return self.applyToolStateAlloc(d, self.arena.allocator());
    }

    fn applyToolStateAlloc(self: *Draft, d: tool.ToolStateChangedData, a: std.mem.Allocator) Error!void {
        const t = self.toolPart(d.part_id);
        std.debug.assert(!isTerminal(t.state)); // the engine settles each tool part once
        t.state = try dupeToolState(a, d.state);
    }

    /// Attach the reasoning signature at block stop. A signed block resends on a tool continuation.
    pub fn finalizeReasoning(self: *Draft, part_id: ids.PartId, signature: []const u8) Error!void {
        const a = self.arena.allocator();
        const part = self.partAt(part_id);
        std.debug.assert(part.* == .reasoning); // the engine finalizes a reasoning block only
        std.debug.assert(part.reasoning.signature.len == 0); // the engine finalizes each part once
        part.reasoning.signature = try a.dupe(u8, signature);
    }

    /// Attach the redacted reasoning data at block stop. The provider encrypts this block, so keep it opaque.
    pub fn finalizeRedacted(self: *Draft, part_id: ids.PartId, data: []const u8) Error!void {
        const a = self.arena.allocator();
        const part = self.partAt(part_id);
        std.debug.assert(part.* == .redacted_reasoning); // the engine finalizes a redacted block only
        std.debug.assert(part.redacted_reasoning.data.len == 0); // the engine finalizes each part once
        part.redacted_reasoning.data = try a.dupe(u8, data);
    }

    /// Give an active tool priority over reasoning after it.
    /// Return `tool_name` from the draft. The draft keeps it valid until it changes.
    pub fn deriveStreamingState(self: *const Draft, run_started_at_ms: u64) activity.ActivityState {
        if (self.firstRunningTool()) |t| return .{ .running_tool = .{
            .run_id = self.run_id,
            .message_id = self.message_id,
            .part_id = t.part_id,
            .tool_name = t.tool_name,
            .started_at_ms = t.started_at_ms,
        } };

        if (self.lastReasoningPart()) |part_id| return .{ .reasoning = .{
            .run_id = self.run_id,
            .message_id = self.message_id,
            .part_id = part_id,
        } };

        return .{ .running = .{
            .run_id = self.run_id,
            .started_at_ms = run_started_at_ms,
        } };
    }

    /// Project the draft to a `proto.ActiveDraft` and share its part payloads.
    /// Encode the result before a change or deinit frees the draft.
    pub fn toActiveDraft(self: *const Draft, scratch: std.mem.Allocator) Error!message.ActiveDraft {
        const content = try scratch.alloc(message.AssistantPart, self.parts.items.len);
        for (self.parts.items, 0..) |*p, i| content[i] = partToWire(p);
        return .{ .message = .{
            .id = self.message_id,
            .run_id = self.run_id,
            .config_rev = self.config_rev,
            .agent = self.agent,
            .content = content,
            .time = .{ .created_at_ms = self.created_at_ms },
        } };
    }

    fn firstRunningTool(self: *const Draft) ?struct { part_id: ids.PartId, tool_name: []const u8, started_at_ms: u64 } {
        for (self.parts.items) |*p| switch (p.*) {
            .tool => |*t| switch (t.state) {
                .running => |r| return .{ .part_id = t.id, .tool_name = t.name, .started_at_ms = r.started_at_ms },
                else => {},
            },
            else => {},
        };
        return null;
    }

    fn lastReasoningPart(self: *const Draft) ?ids.PartId {
        if (self.parts.items.len == 0) return null;
        const last = &self.parts.items[self.parts.items.len - 1];
        return switch (last.*) {
            .reasoning => |*r| r.id,
            else => null,
        };
    }

    /// Resolve the append buffer for a stream text or reasoning part.
    fn streamBuffer(self: *Draft, part_id: ids.PartId) *std.ArrayList(u8) {
        const part = self.partAt(part_id);
        return switch (part.*) {
            .text => |*t| &t.text,
            .reasoning => |*r| &r.text,
            // The engine streams bytes into a text or reasoning part only.
            .redacted_reasoning, .tool => unreachable,
        };
    }

    /// Resolve a tool part by ordinal id.
    fn toolPart(self: *Draft, part_id: ids.PartId) *Part.Tool {
        const part = self.partAt(part_id);
        std.debug.assert(part.* == .tool); // the engine addresses a tool event to a tool part
        return &part.tool;
    }

    /// Resolve a part by ordinal id. The id is the index, so the engine never names a hole.
    fn partAt(self: *Draft, part_id: ids.PartId) *Part {
        const idx = std.math.cast(usize, part_id) orelse unreachable;
        std.debug.assert(idx < self.parts.items.len); // the engine opens a part before it changes it
        const part = &self.parts.items[idx];
        std.debug.assert(part.id() == part_id);
        return part;
    }
};

/// Append a contiguous delta. The producer caps each delta, so the fold asserts the bound here.
fn foldBytes(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), offset: u64, bytes: []const u8, cap: usize) Error!void {
    const have = buf.items.len;
    std.debug.assert(offset == have); // the engine sends each delta once and in order
    std.debug.assert(have <= cap and bytes.len <= cap - have); // the producer checked the cap
    try buf.appendSlice(gpa, bytes);
}

/// Return a wire view that shares an owned part's bytes.
/// Include accumulated output for an active tool.
pub fn partToWire(p: *const Part) message.AssistantPart {
    return switch (p.*) {
        .text => |*t| .{ .text = .{ .id = t.id, .text = t.text.items } },
        .reasoning => |*r| .{ .reasoning = .{ .id = r.id, .text = r.text.items, .signature = r.signature } },
        .redacted_reasoning => |*r| .{ .redacted_reasoning = .{ .id = r.id, .data = r.data } },
        .tool => |*t| .{ .tool = .{
            .id = t.id,
            .call_id = t.call_id,
            .name = t.name,
            .arguments = t.arguments,
            .input_view = t.input_view,
            .state = stateToWire(t),
        } },
    };
}

fn stateToWire(t: *const Part.Tool) tool.ToolState {
    return switch (t.state) {
        .running => |r| .{ .running = .{
            .started_at_ms = r.started_at_ms,
            .output = if (t.output.items.len > 0) t.output.items else null,
        } },
        else => t.state,
    };
}

/// Return output from an active state for the tool output buffer.
fn toolOutputSeed(s: tool.ToolState) []const u8 {
    return switch (s) {
        .running => |r| r.output orelse "",
        else => "",
    };
}

fn isTerminal(s: tool.ToolState) bool {
    return switch (s) {
        .completed, .@"error", .canceled => true,
        .pending, .running => false,
    };
}

/// Clone a tool state into the arena.
/// Store active output in `Tool.output`, not in the state snapshot.
fn dupeToolState(a: std.mem.Allocator, s: tool.ToolState) Error!tool.ToolState {
    return switch (s) {
        .pending => .{ .pending = .{} },
        .running => |r| .{ .running = .{ .started_at_ms = r.started_at_ms, .output = null } },
        .completed, .@"error", .canceled => try proto.dupe(a, s),
    };
}

const testing = std.testing;

const zero_session: ids.SessionId = .bytes(@splat(0));

fn started(agent: []const u8) message.MessageStartedData {
    return .{
        .session_id = zero_session,
        .message_id = 1,
        .run_id = 1,
        .config_rev = 1,
        .agent = agent,
        .created_at_ms = 1000,
    };
}

fn addText(part_id: ids.PartId, text: []const u8) message.MessagePartAddedData {
    return .{ .session_id = zero_session, .message_id = 1, .part = .{ .text = .{ .id = part_id, .text = text } } };
}

fn addTool(part_id: ids.PartId, state: tool.ToolState) message.MessagePartAddedData {
    return .{ .session_id = zero_session, .message_id = 1, .part = .{ .tool = .{
        .id = part_id,
        .name = "bash",
        .arguments = "{}",
        .state = state,
    } } };
}

fn delta(part_id: ids.PartId, offset: u64, bytes: []const u8) message.PartDelta {
    return .{ .session_id = zero_session, .message_id = 1, .part_id = part_id, .delta = bytes, .offset = offset };
}

fn toolStateChange(part_id: ids.PartId, state: tool.ToolState) tool.ToolStateChangedData {
    return .{ .session_id = zero_session, .message_id = 1, .part_id = part_id, .state = state };
}

test "init clones agent and deinit frees the whole draft" {
    var d = try Draft.init(testing.allocator, started("claude"));
    defer d.deinit();
    try testing.expectEqualStrings("claude", d.agent);
    try testing.expectEqual(@as(usize, 0), d.parts.items.len);
}

test "text part streams via contiguous deltas" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(addText(0, ""));
    try d.applyPartDelta(delta(0, 0, "hel"));
    try d.applyPartDelta(delta(0, 3, "lo"));
    try testing.expectEqualStrings("hello", d.parts.items[0].text.text.items);
}

test "part_added may carry initial bytes that deltas extend" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(addText(0, "he"));
    try d.applyPartDelta(delta(0, 2, "llo"));
    try testing.expectEqualStrings("hello", d.parts.items[0].text.text.items);
}

test "reasoning owns its signature; redacted owns its data" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(.{ .session_id = zero_session, .message_id = 1, .part = .{ .reasoning = .{ .id = 0, .text = "why", .signature = "sig" } } });
    try d.addPart(.{ .session_id = zero_session, .message_id = 1, .part = .{ .redacted_reasoning = .{ .id = 1, .data = "opaque" } } });
    try d.applyPartDelta(delta(0, 3, "not"));
    try testing.expectEqualStrings("whynot", d.parts.items[0].reasoning.text.items);
    try testing.expectEqualStrings("sig", d.parts.items[0].reasoning.signature);
    try testing.expectEqualStrings("opaque", d.parts.items[1].redacted_reasoning.data);
}

test "streamed reasoning finalizes its signature and redacted data at block stop" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    // The stream path adds empty parts, sends text, then finalizes at block stop.
    try d.addPart(.{ .session_id = zero_session, .message_id = 1, .part = .{ .reasoning = .{ .id = 0, .text = "", .signature = "" } } });
    try d.addPart(.{ .session_id = zero_session, .message_id = 1, .part = .{ .redacted_reasoning = .{ .id = 1, .data = "" } } });
    try d.applyPartDelta(delta(0, 0, "why"));

    var sig = [_]u8{ 's', 'i', 'g' };
    var enc = [_]u8{ 'e', 'n', 'c' };
    try d.finalizeReasoning(0, &sig);
    try d.finalizeRedacted(1, &enc);
    @memset(&sig, 'x'); // The Draft owns its copies, so the overwrite is safe.
    @memset(&enc, 'x');

    try testing.expectEqualStrings("why", d.parts.items[0].reasoning.text.items);
    try testing.expectEqualStrings("sig", d.parts.items[0].reasoning.signature);
    try testing.expectEqualStrings("enc", d.parts.items[1].redacted_reasoning.data);
}

test "tool output streams into the tool buffer" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(addTool(0, .{ .running = .{ .started_at_ms = 5 } }));
    try testing.expectEqualStrings("bash", d.parts.items[0].tool.name);
    try d.applyToolOutputDelta(delta(0, 0, "out"));
    try d.applyToolOutputDelta(delta(0, 3, "put"));
    try testing.expectEqualStrings("output", d.parts.items[0].tool.output.items);
}

test "tool state transitions from pending to a terminal state" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(addTool(0, .{ .pending = .{} }));

    try d.applyToolState(toolStateChange(0, .{ .running = .{ .started_at_ms = 1 } }));
    try d.applyToolState(toolStateChange(0, .{ .completed = .{ .output = "done", .duration_ms = 9 } }));
    try testing.expect(d.parts.items[0].tool.state == .completed);
    try testing.expectEqualStrings("done", d.parts.items[0].tool.state.completed.output);
}

test "completed tool state with a diff view clones the whole tree" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(addTool(0, .{ .running = .{ .started_at_ms = 1 } }));

    const hunk: view.DiffHunk = .{ .old_start = 1, .old_lines = 1, .new_start = 1, .new_lines = 2, .lines = &.{ "-a", "+a", "+b" } };
    const file: view.DiffFile = .{ .path = "x.zig", .hunks = &.{hunk} };
    const views = [_]view.View{.{ .diff = .{ .files = &.{file} } }};
    const state: tool.ToolState = .{ .completed = .{ .output = "ok", .view = &views, .duration_ms = 3 } };
    try d.applyToolState(toolStateChange(0, state));

    const cloned = d.parts.items[0].tool.state.completed;
    try testing.expectEqualStrings("x.zig", cloned.view.?[0].diff.files[0].path);
    try testing.expectEqualStrings("+b", cloned.view.?[0].diff.files[0].hunks[0].lines[2]);
}

test "a failed tool-state clone changes no field" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(addTool(0, .{ .pending = .{} }));

    const change = toolStateChange(0, .{ .completed = .{ .output = "done", .duration_ms = 2 } });

    var storage: [2]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    try testing.expectError(error.OutOfMemory, d.applyToolStateAlloc(change, fba.allocator()));
    try testing.expect(d.parts.items[0].tool.state == .pending);
}

test "streaming state: running tool outranks a trailing reasoning part" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(addTool(0, .{ .running = .{ .started_at_ms = 7 } }));
    try d.addPart(.{ .session_id = zero_session, .message_id = 1, .part = .{ .reasoning = .{ .id = 1, .text = "", .signature = "" } } });

    const s = d.deriveStreamingState(100);
    try testing.expect(s == .running_tool);
    try testing.expectEqual(@as(ids.PartId, 0), s.running_tool.part_id);
    try testing.expectEqualStrings("bash", s.running_tool.tool_name);
}

test "streaming state: trailing reasoning, else plain running" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(addText(0, "hi"));
    try testing.expectEqual(@as(u64, 42), d.deriveStreamingState(42).running.started_at_ms);

    try d.addPart(.{ .session_id = zero_session, .message_id = 1, .part = .{ .reasoning = .{ .id = 1, .text = "", .signature = "" } } });
    try testing.expect(d.deriveStreamingState(42) == .reasoning);
}

test "toActiveDraft carries the parts and the streamed output" {
    var d = try Draft.init(testing.allocator, started("claude"));
    defer d.deinit();
    try d.addPart(addText(0, ""));
    try d.applyPartDelta(delta(0, 0, "hello"));
    try d.addPart(addTool(1, .{ .running = .{ .started_at_ms = 5 } }));
    _ = try d.applyToolOutputDelta(delta(1, 0, "out"));

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const snapshot = try d.toActiveDraft(scratch.allocator());
    try testing.expectEqualStrings("claude", snapshot.message.agent);
    try testing.expectEqualStrings("hello", snapshot.message.content[0].text.text);
    try testing.expectEqualStrings("out", snapshot.message.content[1].tool.state.running.output.?);
}
