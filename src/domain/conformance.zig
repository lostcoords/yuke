//! Fold one canonical event stream two ways and compare the results.
//! The daemon folds with `applyAuthoritative`. A fresh client folds the same event with `applyBroadcast`.
//! Both paths share one internal dispatch. So this harness proves mode parity across the event set.
//!
//! A committed message is a full snapshot. It hides a missing intermediate event. So the harness
//! compares a semantic `Session.eql` after each event, not only at the end. This is prefix equality.
//!
//! Slice 8 records the events a real daemon turn emits and replays them here. That run proves the
//! daemon publishes every event a client needs. A daemon that mutates but does not publish drifts.

const std = @import("std");
const wire = @import("wire");
const sessionmod = @import("session.zig");

const Session = sessionmod.Session;
const BroadcastData = wire.rpc.BroadcastData;
const ids = wire.ids;

pub const Error = sessionmod.Error || error{
    /// The daemon fold and the client fold produced different projections.
    ConformanceDrift,
    /// The client gapped on a stream that must fold clean.
    UnexpectedGap,
};

/// Drive a daemon fold and a client fold over one canonical stream. Own both projections.
pub const Conformance = struct {
    daemon: Session,
    client: Session,
    scratch: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator, session_id: ids.SessionId) Conformance {
        return .{
            .daemon = Session.init(gpa, session_id),
            .client = Session.init(gpa, session_id),
            .scratch = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Conformance) void {
        self.daemon.deinit();
        self.client.deinit();
        self.scratch.deinit();
        self.* = undefined;
    }

    /// Fold one canonical event both ways. Assert the two projections agree after it.
    /// A well-formed stream never gaps the client.
    pub fn feed(self: *Conformance, bc: BroadcastData) Error!void {
        try self.daemon.applyAuthoritative(bc);
        if (try self.client.applyBroadcast(bc) == .gap) return error.UnexpectedGap;
        _ = self.scratch.reset(.retain_capacity);
        if (!try self.daemon.eql(&self.client, self.scratch.allocator())) return error.ConformanceDrift;
    }

    /// Fold a whole scripted turn. Assert prefix equality after each event.
    pub fn feedAll(self: *Conformance, events: []const BroadcastData) Error!void {
        for (events) |bc| try self.feed(bc);
    }
};

const testing = std.testing;
const content = wire.content;

const sid: ids.SessionId = .bytes(@splat(7));

// A comptime text keeps the content literal in static memory.
fn textInput(comptime t: []const u8) []const content.ContentPart {
    return &.{.{ .text = .{ .text = t } }};
}

fn runStarted(seq: ids.Seq, config_rev: ids.ConfigRev) BroadcastData {
    return .{ .run_started_data = .{ .session_id = sid, .seq = seq, .run_id = 1, .kind = .turn, .config_rev = config_rev, .started_at_ms = 1000 } };
}
fn runDone(seq: ids.Seq) BroadcastData {
    return .{ .run_done_data = .{ .session_id = sid, .seq = seq, .run_id = 1, .kind = .turn, .timing = .{ .ended_at_ms = 2000 }, .outcome = .{ .turn = .{ .finish = .stop, .rounds = 1 } } } };
}
fn configChanged(seq: ids.Seq, config_rev: ids.ConfigRev) BroadcastData {
    return .{ .config_changed_data = .{ .session_id = sid, .seq = seq, .config = .{ .config_rev = config_rev, .model = "opus", .reasoning = "high" } } };
}
fn inputQueued(seq: ids.Seq, input_id: ids.InputId, comptime text: []const u8) BroadcastData {
    return .{ .input_queued_data = .{ .session_id = sid, .seq = seq, .input = .{ .input_id = input_id, .content = textInput(text), .queued_at_ms = 900 } } };
}
fn inputCanceled(seq: ids.Seq, input_id: ids.InputId) BroadcastData {
    return .{ .input_canceled_data = .{ .session_id = sid, .seq = seq, .input_id = input_id } };
}
fn userCommitted(seq: ids.Seq, message_id: ids.MessageId, input_id: ids.InputId, comptime text: []const u8) BroadcastData {
    return .{ .message_committed_data = .{ .session_id = sid, .seq = seq, .message = .{ .user = .{ .id = message_id, .content = textInput(text), .input_id = input_id, .time = .{ .created_at_ms = 950 } } } } };
}
fn assistantCommitted(seq: ids.Seq, message_id: ids.MessageId, config_rev: ids.ConfigRev) BroadcastData {
    return .{ .message_committed_data = .{ .session_id = sid, .seq = seq, .message = .{ .assistant = .{ .id = message_id, .run_id = 1, .config_rev = config_rev, .agent = "claude", .content = &.{}, .time = .{ .created_at_ms = 1500 } } } } };
}
fn truncated(seq: ids.Seq, first_removed_id: ids.MessageId) BroadcastData {
    return .{ .transcript_truncated_data = .{ .session_id = sid, .seq = seq, .first_removed_id = first_removed_id } };
}

fn msgStarted(message_id: ids.MessageId, config_rev: ids.ConfigRev) BroadcastData {
    return .{ .message_started_data = .{ .session_id = sid, .message_id = message_id, .run_id = 1, .config_rev = config_rev, .agent = "claude", .created_at_ms = 1100 } };
}
fn addText(message_id: ids.MessageId, part_id: ids.PartId) BroadcastData {
    return .{ .message_part_added_data = .{ .session_id = sid, .message_id = message_id, .part = .{ .text = .{ .id = part_id, .text = "" } } } };
}
fn addReasoning(message_id: ids.MessageId, part_id: ids.PartId) BroadcastData {
    return .{ .message_part_added_data = .{ .session_id = sid, .message_id = message_id, .part = .{ .reasoning = .{ .id = part_id, .text = "", .signature = "" } } } };
}
fn addRedacted(message_id: ids.MessageId, part_id: ids.PartId) BroadcastData {
    return .{ .message_part_added_data = .{ .session_id = sid, .message_id = message_id, .part = .{ .redacted_reasoning = .{ .id = part_id, .data = "" } } } };
}
fn addTool(message_id: ids.MessageId, part_id: ids.PartId) BroadcastData {
    return .{ .message_part_added_data = .{ .session_id = sid, .message_id = message_id, .part = .{ .tool = .{ .id = part_id, .name = "bash", .arguments = "{}", .state = .{ .pending = .{} } } } } };
}
fn textDelta(message_id: ids.MessageId, part_id: ids.PartId, offset: u64, delta: []const u8) BroadcastData {
    return .{ .message_part_delta_data = .{ .session_id = sid, .message_id = message_id, .part_id = part_id, .delta = delta, .offset = offset } };
}
fn toolOutputDelta(message_id: ids.MessageId, part_id: ids.PartId, offset: u64, delta: []const u8) BroadcastData {
    return .{ .tool_output_delta_data = .{ .session_id = sid, .message_id = message_id, .part_id = part_id, .delta = delta, .offset = offset } };
}
fn finalizeReasoning(message_id: ids.MessageId, part_id: ids.PartId, signature: []const u8) BroadcastData {
    return .{ .message_part_finalized_data = .{ .session_id = sid, .message_id = message_id, .part_id = part_id, .final = .{ .reasoning = .{ .signature = signature } } } };
}
fn finalizeRedacted(message_id: ids.MessageId, part_id: ids.PartId, data: []const u8) BroadcastData {
    return .{ .message_part_finalized_data = .{ .session_id = sid, .message_id = message_id, .part_id = part_id, .final = .{ .redacted_reasoning = .{ .data = data } } } };
}
fn toolRunning(message_id: ids.MessageId, part_id: ids.PartId) BroadcastData {
    return .{ .tool_state_changed_data = .{ .session_id = sid, .message_id = message_id, .part_id = part_id, .state = .{ .running = .{ .started_at_ms = 1200 } } } };
}
fn toolCompleted(message_id: ids.MessageId, part_id: ids.PartId, output: []const u8) BroadcastData {
    return .{ .tool_state_changed_data = .{ .session_id = sid, .message_id = message_id, .part_id = part_id, .state = .{ .completed = .{ .output = output, .duration_ms = 5 } } } };
}
fn discarded(message_id: ids.MessageId) BroadcastData {
    return .{ .message_discarded_data = .{ .session_id = sid, .message_id = message_id } };
}
fn compactionCommitted(seq: ids.Seq, message_id: ids.MessageId) BroadcastData {
    return .{ .message_committed_data = .{ .session_id = sid, .seq = seq, .message = .{ .compaction = .{ .id = message_id, .run_id = 2, .reason = .auto, .summary = "summary", .tokens_before = 100, .tokens_after = 10, .time = .{ .created_at_ms = 1800 } } } } };
}

// The first half of the turn. It builds a rich draft with one part of every kind.
// The durable sequence stays contiguous from 1.
const turn_prefix = [_]BroadcastData{
    // Two inputs queue before the run starts. The first input is canceled.
    inputQueued(1, 100, "cancel me"),
    inputQueued(2, 101, "keep me"),
    inputCanceled(3, 100),
    // The kept input commits as a user message and retires from the queue.
    userCommitted(4, 1, 101, "keep me"),
    // The turn starts and the assistant draft opens.
    runStarted(5, 1),
    msgStarted(2, 1),
    // A text part streams.
    addText(2, 0),
    textDelta(2, 0, 0, "hel"),
    textDelta(2, 0, 3, "lo"),
    // A reasoning part streams. It finalizes its signature at block stop.
    addReasoning(2, 1),
    textDelta(2, 1, 0, "because"),
    finalizeReasoning(2, 1, "sig"),
    // A redacted reasoning part finalizes its opaque data.
    addRedacted(2, 2),
    finalizeRedacted(2, 2, "opaque"),
    // A tool part runs, streams output, and completes.
    addTool(2, 3),
    toolRunning(2, 3),
    toolOutputDelta(2, 3, 0, "out"),
    toolCompleted(2, 3, "done"),
};

// The second half of the turn. It commits, discards, compacts, truncates, and queues.
const turn_suffix = [_]BroadcastData{
    // A config change advances the cursor.
    configChanged(6, 2),
    // The assistant message commits and clears the draft.
    assistantCommitted(7, 2, 1),
    runDone(8),
    // The daemon discards a second draft instead of committing it.
    runStarted(9, 2),
    msgStarted(3, 2),
    addText(3, 0),
    textDelta(3, 0, 0, "oops"),
    discarded(3),
    runDone(10),
    // A compaction message commits and raises the finalized high-water.
    compactionCommitted(11, 4),
    // Truncation advances the cursor.
    truncated(12, 1),
    // A late input queues then cancels while idle.
    inputQueued(13, 200, "later"),
    inputCanceled(14, 200),
};

test "a full scripted turn folds identically on both sides after every event" {
    var conf = Conformance.init(testing.allocator, sid);
    defer conf.deinit();

    // Fold the draft-building half. The two folds stay equal after each event.
    try conf.feedAll(&turn_prefix);

    // An independent oracle: the fold built the expected draft content.
    // A fold that drops deltas or parts fails here, even though the two sides still match.
    const d = &conf.daemon.active.?;
    try testing.expectEqual(@as(usize, 4), d.parts.items.len);
    try testing.expectEqualStrings("hello", d.parts.items[0].text.text.items);
    try testing.expectEqualStrings("because", d.parts.items[1].reasoning.text.items);
    try testing.expectEqualStrings("sig", d.parts.items[1].reasoning.signature);
    try testing.expectEqualStrings("opaque", d.parts.items[2].redacted_reasoning.data);
    try testing.expect(d.parts.items[3].tool.state == .completed);
    try testing.expectEqualStrings("done", d.parts.items[3].tool.state.completed.output);

    // Fold the terminal half.
    try conf.feedAll(&turn_suffix);

    // The terminal state has no draft or queued input. The durable sequence is 14.
    try testing.expect(conf.daemon.active == null);
    try testing.expectEqual(@as(usize, 0), conf.daemon.queue.depth());
    try testing.expectEqual(@as(ids.Seq, 14), conf.daemon.base_seq);
    try testing.expectEqual(@as(ids.MessageId, 4), conf.daemon.finalized_message_id);
}

test "the harness catches a client fold that drifts" {
    var conf = Conformance.init(testing.allocator, sid);
    defer conf.deinit();

    // Fold a start and a part on both sides.
    try conf.feed(msgStarted(1, 1));
    try conf.feed(addText(1, 0));
    try conf.feed(textDelta(1, 0, 0, "hi"));

    // Fold an extra delta into the client alone. The next shared event drifts the two folds.
    _ = try conf.client.applyBroadcast(textDelta(1, 0, 2, "!"));
    try testing.expectError(error.ConformanceDrift, conf.feed(textDelta(1, 0, 2, "?")));
}
