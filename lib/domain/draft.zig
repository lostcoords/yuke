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
    /// Reject a finalization that conflicts with the existing metadata.
    ConflictingFinalization,
    OutOfMemory,
};

/// Describe the result of a byte-delta fold by offset.
pub const DeltaOutcome = enum {
    /// Apply a delta at the accumulated length.
    applied,
    /// Ignore a duplicate delta whose bytes the draft already owns.
    stale,
    /// Return a gap for a hole or stream-cap overflow.
    gap,
};

/// Describe the result of a tool-state fold.
pub const ToolOutcome = enum {
    /// Apply the transition.
    applied,
    /// Ignore a non-terminal state after a terminal state.
    ignored_terminal,
};

/// Describe the result of a reasoning-part finalization.
pub const FinalizationOutcome = enum {
    /// Store the final metadata.
    applied,
    /// Ignore identical final metadata.
    ignored_duplicate,
};

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
        permission_state: ?permission.PermissionState = null,
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
                    .input_view = if (t.input_view) |v| try wire.dupe(arena, v) else null,
                    .output = output,
                    .state = try dupeToolState(arena, t.state),
                    .permission_state = if (t.permission_state) |ps| try wire.dupe(arena, ps) else null,
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
        // Check the ordinal before the clone, so a rejected event allocates nothing.
        // Only a client that missed a part_added sees a mismatch. The daemon builds ids in order.
        if (p.id() != expected) return error.PartOutOfOrder;
        var cloned = try Part.initFrom(self.gpa, self.arena.allocator(), p);
        errdefer cloned.deinit(self.gpa);
        try self.parts.append(self.gpa, cloned);
    }

    /// Fold a text or reasoning byte delta from `message.part_delta` into its buffer.
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
        return self.applyToolStateAlloc(d, self.arena.allocator());
    }

    fn applyToolStateAlloc(self: *Draft, d: tool.ToolStateChangedData, a: std.mem.Allocator) Error!ToolOutcome {
        const t = try self.toolPart(d.part_id);
        if (isTerminal(t.state) and !isTerminal(d.state)) return .ignored_terminal;
        const next_state = try dupeToolState(a, d.state);
        const next_permission = if (d.permission_state) |ps| try wire.dupe(a, ps) else null;
        t.state = next_state;
        // Leave the current permission state unchanged when `permission_state` is null.
        if (next_permission) |ps| t.permission_state = ps;
        return .applied;
    }

    /// Attach the reasoning signature at block stop. A signed block resends on a tool continuation.
    pub fn finalizeReasoning(self: *Draft, part_id: ids.PartId, signature: []const u8) Error!FinalizationOutcome {
        return self.finalizeReasoningAlloc(part_id, signature, self.arena.allocator());
    }

    fn finalizeReasoningAlloc(self: *Draft, part_id: ids.PartId, signature: []const u8, a: std.mem.Allocator) Error!FinalizationOutcome {
        const part = try self.partAt(part_id);
        switch (part.*) {
            .reasoning => |*r| {
                if (std.mem.eql(u8, r.signature, signature)) return .ignored_duplicate;
                if (r.signature.len != 0) return error.ConflictingFinalization;
                r.signature = try a.dupe(u8, signature);
                return .applied;
            },
            else => return error.WrongPartKind,
        }
    }

    /// Attach the redacted reasoning data at block stop. The provider encrypts this block, so keep it opaque.
    pub fn finalizeRedacted(self: *Draft, part_id: ids.PartId, data: []const u8) Error!FinalizationOutcome {
        return self.finalizeRedactedAlloc(part_id, data, self.arena.allocator());
    }

    fn finalizeRedactedAlloc(self: *Draft, part_id: ids.PartId, data: []const u8, a: std.mem.Allocator) Error!FinalizationOutcome {
        const part = try self.partAt(part_id);
        switch (part.*) {
            .redacted_reasoning => |*r| {
                if (std.mem.eql(u8, r.data, data)) return .ignored_duplicate;
                if (r.data.len != 0) return error.ConflictingFinalization;
                r.data = try a.dupe(u8, data);
                return .applied;
            },
            else => return error.WrongPartKind,
        }
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

    /// Project the draft to a `wire.ActiveDraft` and share its part payloads.
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

    /// Resolve the append buffer for a stream text or reasoning part.
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
fn foldBytes(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), offset: u64, bytes: []const u8, cap: usize) Error!DeltaOutcome {
    const have = buf.items.len;
    if (offset > have) return .gap;
    if (offset < have) return .stale;
    if (have > cap or bytes.len > cap - have) return .gap;
    try buf.appendSlice(gpa, bytes);
    return .applied;
}

/// Return a wire view that shares an owned part's bytes.
/// Include accumulated output for an active tool.
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

/// Return output from an active state for the tool output buffer.
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
/// Store active output in `Tool.output`, not in the state snapshot.
fn dupeToolState(a: std.mem.Allocator, s: tool.ToolState) Error!tool.ToolState {
    return switch (s) {
        .pending => .{ .pending = .{} },
        .waiting_permission => .{ .waiting_permission = .{} },
        .running => |r| .{ .running = .{ .started_at_ms = r.started_at_ms, .output = null } },
        .completed, .@"error", .denied, .canceled => try wire.dupe(a, s),
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

test "foldBytes rejects a delta that would exceed the cap" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // A delta up to the cap is applied. A contiguous delta one byte over is a gap.
    try testing.expectEqual(DeltaOutcome.applied, try foldBytes(testing.allocator, &buf, 0, "abc", 3));
    try testing.expectEqual(DeltaOutcome.gap, try foldBytes(testing.allocator, &buf, 3, "x", 3));
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

test "streamed reasoning finalizes its signature and redacted data at block stop" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    // The stream path adds empty parts, sends text, then finalizes at block stop.
    try d.addPart(.{ .session_id = zero_session, .message_id = 1, .part = .{ .reasoning = .{ .id = 0, .text = "", .signature = "" } } });
    try d.addPart(.{ .session_id = zero_session, .message_id = 1, .part = .{ .redacted_reasoning = .{ .id = 1, .data = "" } } });
    _ = try d.applyPartDelta(delta(0, 0, "why"));

    var sig = [_]u8{ 's', 'i', 'g' };
    var enc = [_]u8{ 'e', 'n', 'c' };
    _ = try d.finalizeReasoning(0, &sig);
    _ = try d.finalizeRedacted(1, &enc);
    @memset(&sig, 'x'); // The Draft owns its copies, so the overwrite is safe.
    @memset(&enc, 'x');

    try testing.expectEqualStrings("why", d.parts.items[0].reasoning.text.items);
    try testing.expectEqualStrings("sig", d.parts.items[0].reasoning.signature);
    try testing.expectEqualStrings("enc", d.parts.items[1].redacted_reasoning.data);
    try testing.expectError(error.WrongPartKind, d.finalizeReasoning(1, &sig));
    try testing.expectError(error.WrongPartKind, d.finalizeRedacted(0, &enc));
}

test "identical finalization is allocation-free and conflicts are rejected" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(.{ .session_id = zero_session, .message_id = 1, .part = .{ .reasoning = .{ .id = 0, .text = "", .signature = "" } } });
    try d.addPart(.{ .session_id = zero_session, .message_id = 1, .part = .{ .redacted_reasoning = .{ .id = 1, .data = "" } } });

    var no_storage: [0]u8 = .{};
    var fba = std.heap.FixedBufferAllocator.init(&no_storage);
    try testing.expectEqual(FinalizationOutcome.ignored_duplicate, try d.finalizeReasoningAlloc(0, "", fba.allocator()));
    try testing.expectEqual(FinalizationOutcome.ignored_duplicate, try d.finalizeRedactedAlloc(1, "", fba.allocator()));

    try testing.expectEqual(FinalizationOutcome.applied, try d.finalizeReasoning(0, "sig"));
    try testing.expectEqual(FinalizationOutcome.applied, try d.finalizeRedacted(1, "data"));
    try testing.expectEqual(FinalizationOutcome.ignored_duplicate, try d.finalizeReasoningAlloc(0, "sig", fba.allocator()));
    try testing.expectEqual(FinalizationOutcome.ignored_duplicate, try d.finalizeRedactedAlloc(1, "data", fba.allocator()));
    try testing.expectError(error.ConflictingFinalization, d.finalizeReasoningAlloc(0, "other", fba.allocator()));
    try testing.expectError(error.ConflictingFinalization, d.finalizeRedactedAlloc(1, "other", fba.allocator()));
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

test "a failed tool-state clone changes no field" {
    var d = try Draft.init(testing.allocator, started("a"));
    defer d.deinit();
    try d.addPart(addTool(0, .{ .pending = .{} }));

    const options = [_]permission.PermissionOption{.{ .id = "allow", .kind = .allow_once, .label = "Allow" }};
    var change = toolStateChange(0, .{ .denied = .{ .reason = "no", .denied_by = .policy } });
    change.permission_state = .{ .requested_at_ms = 1, .options = &options };

    var storage: [2]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    try testing.expectError(error.OutOfMemory, d.applyToolStateAlloc(change, fba.allocator()));
    try testing.expect(d.parts.items[0].tool.state == .pending);
    try testing.expectEqual(null, d.parts.items[0].tool.permission_state);
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
