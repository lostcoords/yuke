//! Fold broadcast events in the daemon and client. Copy bytes before `apply` returns.
//! Keep the Draft address stable. Let `gpa` own streamed buffers and `arena` own write-once data.

const std = @import("std");
const wire = @import("wire");

const ids = wire.ids;
const message = wire.message;
const tool = wire.tool;
const view = wire.view;
const permission = wire.permission;
const activity = wire.activity;

/// Return errors for untrusted peer broadcasts.
/// Let the daemon assert the state after validation.
pub const Error = error{
    /// Reject a delta for a part that the draft has not opened.
    UnknownPart,
    /// Reject a delta for a part of the wrong kind.
    WrongPartKind,
    /// Reject a `part_added` id that is not the next ordinal.
    PartOutOfOrder,
    OutOfMemory,
};

/// Describe the result of folding a byte delta by offset.
pub const DeltaOutcome = enum {
    /// Apply a delta at the accumulated length.
    applied,
    /// Ignore a duplicate delta whose bytes are already held.
    stale,
    /// Return a gap for a hole or stream-cap overflow.
    gap,
};

/// Describe the result of folding a tool-state transition.
pub const ToolOutcome = enum {
    /// Apply the transition.
    applied,
    /// Ignore a non-terminal state after a terminal state.
    ignored_terminal,
};

/// Own streamed buffers and arena-backed fields for one draft part.
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
        permission_state: ?permission.PermissionState = null,
    };

    /// Treat the protocol part id as the index in `Draft.parts`.
    pub fn id(self: Part) ids.PartId {
        return switch (self) {
            inline else => |p| p.id,
        };
    }

    /// Free streamed buffers owned by `gpa`.
    fn deinit(self: *Part, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .text => |*t| t.text.deinit(gpa),
            .reasoning => |*r| r.text.deinit(gpa),
            .redacted_reasoning => {},
            .tool => |*t| t.output.deinit(gpa),
        }
    }

    /// Build an owned part from a wire part. `gpa` backs streamed buffers; `arena` backs write-once
    /// data. `deinit` frees the streamed buffers; the arena stays the caller's.
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
                // Seed output from a running snapshot; live parts start empty.
                var output: std.ArrayList(u8) = .empty;
                try output.appendSlice(gpa, toolOutputSeed(t.state));
                errdefer output.deinit(gpa);

                return .{ .tool = .{
                    .id = t.id,
                    .call_id = if (t.call_id) |c| try arena.dupe(u8, c) else null,
                    .name = try arena.dupe(u8, t.name),
                    .arguments = try arena.dupe(u8, t.arguments),
                    .input_view = if (t.input_view) |v| try wire.dupe(arena, v) else null,
                    .output = output,
                    .state = try dupeToolState(arena, t.state),
                    .permission_state = if (t.permission_state) |ps| try wire.dupe(arena, ps) else null,
                } };
            },
        }
    }
};

/// Fold broadcast events into an in-flight assistant message.
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
    /// Reject an out-of-order id when a part event is missing.
    pub fn addPart(self: *Draft, d: message.MessagePartAddedData) Error!void {
        return self.appendPart(d.part);
    }

    /// Clone a wire part. Check its ordinal and append it.
    fn appendPart(self: *Draft, p: message.AssistantPart) Error!void {
        const expected: ids.PartId = @intCast(self.parts.items.len);
        var cloned = try Part.initFrom(self.gpa, self.arena.allocator(), p);
        errdefer cloned.deinit(self.gpa);
        // Only a client that missed a part_added sees a mismatch. The daemon builds ids in order.
        if (cloned.id() != expected) return error.PartOutOfOrder;
        try self.parts.append(self.gpa, cloned);
    }

    /// Fold a text/reasoning byte delta from `message.part_delta` into its buffer.
    pub fn applyPartDelta(self: *Draft, d: message.PartDelta) Error!DeltaOutcome {
        const buf = try self.streamBuffer(d.part_id);
        const cap: usize = @intCast(wire.meta.limits.max_message_string_bytes);
        return foldBytes(self.gpa, buf, d.offset, d.delta, cap);
    }

    /// Fold a `tool.output_delta` into the tool output buffer.
    /// Return a gap when the stream cap would be exceeded.
    pub fn applyToolOutputDelta(self: *Draft, d: message.PartDelta) Error!DeltaOutcome {
        const t = try self.toolPart(d.part_id);
        const cap: usize = @intCast(wire.meta.limits.max_tool_output_stream_bytes);
        return foldBytes(self.gpa, &t.output, d.offset, d.delta, cap);
    }

    /// Fold a `tool.state_changed` event.
    /// Ignore a non-terminal update after a terminal state.
    pub fn applyToolState(self: *Draft, d: tool.ToolStateChangedData) Error!ToolOutcome {
        const t = try self.toolPart(d.part_id);
        if (isTerminal(t.state) and !isTerminal(d.state)) return .ignored_terminal;
        const a = self.arena.allocator();
        t.state = try dupeToolState(a, d.state);
        // Leave the current permission state unchanged when `permission_state` is null.
        if (d.permission_state) |ps| t.permission_state = try wire.dupe(a, ps);
        return .applied;
    }

    /// Give a running tool priority over trailing reasoning.
    /// Return `tool_name` borrowed from the draft; it stays valid until the draft changes.
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

    /// Check whether an activity locator matches the draft.
    /// Treat states without a draft locator as consistent.
    pub fn activityConsistent(self: *const Draft, state: activity.ActivityState) bool {
        return switch (state) {
            .running_tool => |s| self.toolLocatorMatches(s.part_id, s.tool_name, .running),
            .waiting_permission => |s| self.toolLocatorMatches(s.part_id, s.tool_name, .waiting_permission),
            .reasoning => |s| if (self.constPartAt(s.part_id)) |p| p.* == .reasoning else false,
            .idle, .building, .running, .retrying, .compacting => true,
        };
    }

    /// Project the draft to a `wire.ActiveDraft` without copying part payloads.
    /// Encode the result before the draft changes or is freed.
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

    /// Rebuild an owned draft from a resync snapshot.
    pub fn fromActiveDraft(gpa: std.mem.Allocator, ad: message.ActiveDraft) Error!Draft {
        const m = ad.message;
        var self: Draft = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .message_id = m.id,
            .run_id = m.run_id,
            .config_rev = m.config_rev,
            .agent = "",
            .created_at_ms = m.time.created_at_ms,
        };
        errdefer self.deinit();
        self.agent = try self.arena.allocator().dupe(u8, m.agent);
        for (m.content) |p| try self.appendPart(p);
        return self;
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

    fn toolLocatorMatches(self: *const Draft, part_id: ids.PartId, tool_name: []const u8, tag: std.meta.Tag(tool.ToolState)) bool {
        const p = self.constPartAt(part_id) orelse return false;
        return switch (p.*) {
            .tool => |*t| std.mem.eql(u8, t.name, tool_name) and std.meta.activeTag(t.state) == tag,
            else => false,
        };
    }

    fn constPartAt(self: *const Draft, part_id: ids.PartId) ?*const Part {
        const idx = std.math.cast(usize, part_id) orelse return null;
        if (idx >= self.parts.items.len) return null;
        const p = &self.parts.items[idx];
        if (p.id() != part_id) return null;
        return p;
    }

    /// Resolve the append buffer for a streamed text or reasoning part.
    fn streamBuffer(self: *Draft, part_id: ids.PartId) Error!*std.ArrayList(u8) {
        const part = try self.partAt(part_id);
        return switch (part.*) {
            .text => |*t| &t.text,
            .reasoning => |*r| &r.text,
            .redacted_reasoning, .tool => error.WrongPartKind,
        };
    }

    /// Resolve a tool part by ordinal id.
    fn toolPart(self: *Draft, part_id: ids.PartId) Error!*Part.Tool {
        const part = try self.partAt(part_id);
        return switch (part.*) {
            .tool => |*t| t,
            else => error.WrongPartKind,
        };
    }

    /// Resolve a part by ordinal id. Return `UnknownPart` for a mismatch or hole.
    fn partAt(self: *Draft, part_id: ids.PartId) Error!*Part {
        const idx = std.math.cast(usize, part_id) orelse return error.UnknownPart;
        if (idx >= self.parts.items.len) return error.UnknownPart;
        const part = &self.parts.items[idx];
        if (part.id() != part_id) return error.UnknownPart;
        return part;
    }
};

/// Apply only a contiguous delta.
/// Return `stale` for duplicates and `gap` for holes or cap overruns.
fn foldBytes(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), offset: u64, bytes: []const u8, cap: ?usize) Error!DeltaOutcome {
    const have = buf.items.len;
    if (offset > have) return .gap;
    if (offset < have) return .stale;
    if (cap) |c| if (have > c or bytes.len > c - have) return .gap;
    try buf.appendSlice(gpa, bytes);
    return .applied;
}

/// Return a zero-copy wire view of an owned part.
/// Include accumulated output for a running tool.
fn partToWire(p: *const Part) message.AssistantPart {
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
            .permission_state = t.permission_state,
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

/// Return output from a running state for the tool output buffer.
fn toolOutputSeed(s: tool.ToolState) []const u8 {
    return switch (s) {
        .running => |r| r.output orelse "",
        else => "",
    };
}

fn isTerminal(s: tool.ToolState) bool {
    return switch (s) {
        .completed, .@"error", .denied, .canceled => true,
        .pending, .running, .waiting_permission => false,
    };
}

/// Clone a tool state into the arena.
/// Store running output in `Tool.output`, not in the state snapshot.
fn dupeToolState(a: std.mem.Allocator, s: tool.ToolState) Error!tool.ToolState {
    return switch (s) {
        .pending => .{ .pending = .{} },
        .waiting_permission => .{ .waiting_permission = .{} },
        .running => |r| .{ .running = .{ .started_at_ms = r.started_at_ms, .output = null } },
        .completed, .@"error", .denied, .canceled => try wire.dupe(a, s),
    };
}

const testing = std.testing;

const zero_session: ids.SessionId = @splat(0);

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
    try testing.expectEqual(DeltaOutcome.applied, try d.applyPartDelta(delta(0, 0, "hel")));
    try testing.expectEqual(DeltaOutcome.applied, try d.applyPartDelta(delta(0, 3, "lo")));
    try testing.expectEqualStrings("hello", d.parts.items[0].text.text.items);
}

test "part_added may carry initial bytes that deltas extend" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(addText(0, "he"));
    try testing.expectEqual(DeltaOutcome.applied, try d.applyPartDelta(delta(0, 2, "llo")));
    try testing.expectEqualStrings("hello", d.parts.items[0].text.text.items);
}

test "stale delta is ignored, gap is reported" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(addText(0, ""));
    _ = try d.applyPartDelta(delta(0, 0, "hello"));
    try testing.expectEqual(DeltaOutcome.stale, try d.applyPartDelta(delta(0, 0, "hel")));
    try testing.expectEqual(DeltaOutcome.gap, try d.applyPartDelta(delta(0, 99, "x")));
    try testing.expectEqualStrings("hello", d.parts.items[0].text.text.items);
}

test "reasoning owns its signature; redacted owns its data" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(.{ .session_id = zero_session, .message_id = 1, .part = .{ .reasoning = .{ .id = 0, .text = "why", .signature = "sig" } } });
    try d.addPart(.{ .session_id = zero_session, .message_id = 1, .part = .{ .redacted_reasoning = .{ .id = 1, .data = "opaque" } } });
    _ = try d.applyPartDelta(delta(0, 3, "not"));
    try testing.expectEqualStrings("whynot", d.parts.items[0].reasoning.text.items);
    try testing.expectEqualStrings("sig", d.parts.items[0].reasoning.signature);
    try testing.expectEqualStrings("opaque", d.parts.items[1].redacted_reasoning.data);
}

test "tool output streams; a text delta to a tool part is WrongPartKind" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(addTool(0, .{ .running = .{ .started_at_ms = 5 } }));
    try testing.expectEqualStrings("bash", d.parts.items[0].tool.name);
    try testing.expectEqual(DeltaOutcome.applied, try d.applyToolOutputDelta(delta(0, 0, "out")));
    try testing.expectEqual(DeltaOutcome.applied, try d.applyToolOutputDelta(delta(0, 3, "put")));
    try testing.expectEqualStrings("output", d.parts.items[0].tool.output.items);
    try testing.expectError(error.WrongPartKind, d.applyPartDelta(delta(0, 0, "x")));
}

test "tool state transitions, and terminal is monotonic" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(addTool(0, .{ .pending = .{} }));

    try testing.expectEqual(ToolOutcome.applied, try d.applyToolState(toolStateChange(0, .{ .running = .{ .started_at_ms = 1 } })));
    try testing.expectEqual(ToolOutcome.applied, try d.applyToolState(toolStateChange(0, .{ .completed = .{ .output = "done", .duration_ms = 9 } })));
    try testing.expect(d.parts.items[0].tool.state == .completed);
    try testing.expectEqualStrings("done", d.parts.items[0].tool.state.completed.output);

    try testing.expectEqual(ToolOutcome.ignored_terminal, try d.applyToolState(toolStateChange(0, .{ .running = .{ .started_at_ms = 2 } })));
    try testing.expect(d.parts.items[0].tool.state == .completed);
}

test "completed tool state with a diff view clones the whole tree" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(addTool(0, .{ .running = .{ .started_at_ms = 1 } }));

    const hunk: view.DiffHunk = .{ .old_start = 1, .old_lines = 1, .new_start = 1, .new_lines = 2, .lines = &.{ "-a", "+a", "+b" } };
    const file: view.DiffFile = .{ .path = "x.zig", .hunks = &.{hunk} };
    const views = [_]view.View{.{ .diff = .{ .files = &.{file} } }};
    const state: tool.ToolState = .{ .completed = .{ .output = "ok", .view = &views, .duration_ms = 3 } };
    try testing.expectEqual(ToolOutcome.applied, try d.applyToolState(toolStateChange(0, state)));

    const cloned = d.parts.items[0].tool.state.completed;
    try testing.expectEqualStrings("x.zig", cloned.view.?[0].diff.files[0].path);
    try testing.expectEqualStrings("+b", cloned.view.?[0].diff.files[0].hunks[0].lines[2]);
}

test "delta to an unopened part is UnknownPart; out-of-order add is rejected" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try testing.expectError(error.UnknownPart, d.applyPartDelta(delta(0, 0, "x")));
    try testing.expectError(error.PartOutOfOrder, d.addPart(addText(5, "")));
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

test "activityConsistent detects a drifted locator" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(addTool(0, .{ .running = .{ .started_at_ms = 1 } }));

    try testing.expect(d.activityConsistent(.{ .running_tool = .{ .run_id = 1, .message_id = 1, .part_id = 0, .tool_name = "bash", .started_at_ms = 1 } }));
    try testing.expect(!d.activityConsistent(.{ .running_tool = .{ .run_id = 1, .message_id = 1, .part_id = 0, .tool_name = "python", .started_at_ms = 1 } }));
    try testing.expect(!d.activityConsistent(.{ .reasoning = .{ .run_id = 1, .message_id = 1, .part_id = 0 } }));
    try testing.expect(d.activityConsistent(.{ .idle = .{} }));
}

test "toActiveDraft then fromActiveDraft round-trips parts and streamed output" {
    var d = try Draft.init(testing.allocator, started("claude"));
    defer d.deinit();
    try d.addPart(addText(0, ""));
    _ = try d.applyPartDelta(delta(0, 0, "hello"));
    try d.addPart(addTool(1, .{ .running = .{ .started_at_ms = 5 } }));
    _ = try d.applyToolOutputDelta(delta(1, 0, "out"));

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const snapshot = try d.toActiveDraft(scratch.allocator());
    try testing.expectEqualStrings("out", snapshot.message.content[1].tool.state.running.output.?);

    var d2 = try Draft.fromActiveDraft(testing.allocator, snapshot);
    defer d2.deinit();
    try testing.expectEqualStrings("claude", d2.agent);
    try testing.expectEqualStrings("hello", d2.parts.items[0].text.text.items);
    try testing.expectEqualStrings("out", d2.parts.items[1].tool.output.items);
    try testing.expectEqualStrings("bash", d2.parts.items[1].tool.name);
}
