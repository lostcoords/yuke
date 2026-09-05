//! The engine handle on the Host: it marks sessions dirty from engine tasks and drains one digest per frame.

const std = @import("std");
const quickjs = @import("quickjs");
const zio = @import("zio");
const proto = @import("proto");
const host_mod = @import("../../host.zig");
const module = @import("../module.zig");
const App = @import("../../../app/app.zig").App;

const Host = host_mod.Host;
const Context = quickjs.Context;
const Value = quickjs.Value;
const SessionId = proto.ids.SessionId;

/// Bound the dirty set so a storm cannot grow it without limit. A full set marks everything dirty.
pub const max_dirty_sessions: usize = 256;
/// The module state on the Host.
pub const Engine = struct {
    gpa: std.mem.Allocator,
    /// The app installs this after `App.open`. A null app answers every call as "not ready".
    runtime: ?*App = null,
    /// The JavaScript sink, held as a GC root. `drain` calls it on the owner.
    sink: Value,
    ctx: Context,
    /// Sessions that changed since the last drain, and how each changed.
    dirty: std.AutoHashMapUnmanaged(SessionId, Change) = .empty,
    /// The session index changed, so the list view must reread it.
    index_dirty: bool = false,
    /// The facts that named no session. A plugin reads them beside the index change.
    index_facts: FactSet = .initEmpty(),
    /// Set when the dirty set overflowed; `drain` then reports an index change, so no lost event leaves a stale view.
    dirty_overflow: bool = false,
    /// The owner sleeps until this fires. An engine task sets it so a change reaches the next frame.
    wake: ?*zio.ResetEvent = null,
    /// An event sink threw. `drain` reports it so the owner can note the fault, as a key press does.
    faulted: bool = false,

    pub fn create(gpa: std.mem.Allocator, ctx: Context) !*Engine {
        const self = try gpa.create(Engine);
        self.* = .{ .gpa = gpa, .ctx = ctx, .sink = quickjs.UNDEFINED };
        return self;
    }

    pub fn destroy(self: *Engine) void {
        std.debug.assert(self.runtime == null); // detach must run before the context closes
        self.ctx.freeValue(self.sink);
        self.dirty.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Subscribe this engine to `state`. A second attach is a wiring bug, not a silent replacement.
    pub fn attach(self: *Engine, runtime: *App) void {
        std.debug.assert(self.runtime == null); // one engine, one attach
        self.runtime = runtime;
        runtime.engine.sinks.add(.{ .ctx = @ptrCast(self), .on_event = onEvent });
    }

    /// Stop event delivery before the state closes. Remove only this engine, so a detach never silences another frontend.
    pub fn detach(self: *Engine) void {
        const runtime = self.runtime orelse return;
        runtime.engine.sinks.remove(@ptrCast(self));
        self.runtime = null;
    }

    /// Mark the event's session dirty. This runs on an engine task, so it must not enter JavaScript.
    fn onEvent(ctx: *anyopaque, note: proto.rpc.Notification) void {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        const id = sessionOf(note) orelse {
            self.index_dirty = true;
            self.index_facts.insert(note.method);
            self.wakeOwner();
            return;
        };
        self.markDirty(id, Change.of(note));
        self.wakeOwner();
    }

    /// Report whether `drain` has anything to deliver. The owner asks before it sleeps.
    pub fn hasPending(self: *const Engine) bool {
        return self.index_dirty or self.dirty_overflow or self.dirty.count() != 0;
    }

    /// Wake the owner so it drains this event on the next frame, not on the next keystroke.
    fn wakeOwner(self: *Engine) void {
        if (self.wake) |event| event.set();
    }

    fn markDirty(self: *Engine, id: SessionId, change: Change) void {
        if (self.dirty.getPtr(id)) |held| return held.merge(change);
        if (self.dirty.count() >= max_dirty_sessions) {
            self.dirty_overflow = true;
            return;
        }
        self.dirty.put(self.gpa, id, change) catch {
            self.dirty_overflow = true;
        };
    }
};

/// The facts one drain carries. A digest coalesces them, so a repeat within a frame reads as one.
pub const FactSet = std.EnumSet(proto.enums.BroadcastName);

/// How one session changed since the last drain. A view redraws differently for each kind.
pub const Change = struct {
    /// The work this change leaves the transcript.
    view: View = .quiet,
    /// Every fact this session saw since the last drain. A view ignores it; a plugin reads it.
    facts: FactSet = .initEmpty(),

    /// What one drain asks the transcript to do. The order of the fields is the merge order.
    pub const View = union(enum) {
        /// Nothing the transcript draws moved. The plugins still read the facts.
        quiet,
        /// Only this message moved. With a part, only that part moved, so the view re-wraps one part.
        message: struct { id: proto.ids.MessageId, part: ?proto.ids.PartId },
        /// The outline moved, so the view reads it again.
        reload,
        /// The session is gone. This outranks every other kind.
        gone,

        /// Rank the kinds so a merge keeps the stronger one.
        fn rank(self: View) u8 {
            return @intFromEnum(self);
        }
    };

    /// Classify one event by the projection it moves, then record it as a fact.
    fn of(note: proto.rpc.Notification) Change {
        var change: Change = .{ .view = viewOf(note) };
        change.facts.insert(note.method);
        return change;
    }

    /// Reload only when the message set or the draft state changes.
    fn viewOf(note: proto.rpc.Notification) View {
        return switch (note.params) {
            .session_removed_data => .gone,
            // These move the parts of one message and leave the outline alone.
            .message_part_added_data => |d| .{ .message = .{ .id = d.message_id, .part = d.part.id() } },
            inline .message_part_delta_data,
            .message_part_finalized_data,
            .tool_state_changed_data,
            .tool_output_delta_data,
            => |d| .{ .message = .{ .id = d.message_id, .part = d.part_id } },
            // These open or close the draft, or move the committed set.
            .message_started_data,
            .message_discarded_data,
            .message_committed_data,
            .transcript_truncated_data,
            => .reload,
            // The rest carries no transcript state. The activity, the queue, and the run draw elsewhere.
            .session_summary_changed_data,
            .session_activity_changed_data,
            .catalog_changed_data,
            .auth_login_finished_data,
            .auth_changed_data,
            .notice,
            .interaction_requested_data,
            .run_started_data,
            .run_done_data,
            .config_changed_data,
            .input_queued_data,
            .input_canceled_data,
            => .quiet,
        };
    }

    /// Fold a later event into an earlier one. The stronger kind wins, so no update is lost.
    fn merge(self: *Change, other: Change) void {
        // A fact never loses to a stronger kind, because the two answer different questions.
        self.facts.setUnion(other.facts);
        self.view = strongest(self.view, other.view);
    }

    /// Combine two kinds. Two parts widen to their message, and two messages widen to a reload.
    fn strongest(a: View, b: View) View {
        if (a == .message and b == .message) {
            if (a.message.id != b.message.id) return .reload;
            if (a.message.part != b.message.part) return .{ .message = .{ .id = a.message.id, .part = null } };
        }
        return if (b.rank() > a.rank()) b else a;
    }

    /// Name the kind for the sink. A view branches on this string; a plugin reads the facts instead.
    fn kind(self: Change) [:0]const u8 {
        return switch (self.view) {
            .quiet => "quiet",
            .message => "active",
            .reload => "reload",
            .gone => "gone",
        };
    }
};

/// Read the session an event belongs to. An index event names no session.
pub fn sessionOf(note: proto.rpc.Notification) ?SessionId {
    return switch (note.params) {
        inline else => |payload| if (@hasField(@TypeOf(payload), "session_id")) payload.session_id else null,
    };
}

/// Deliver the sessions that changed since the last call. Only the owner calls this, between frames. True when a sink threw.
pub fn drain(engine: *Engine, ctx: Context) bool {
    // Take the batch before the first callback, because a sink can publish an event that writes the dirty map.
    var batch: [max_dirty_sessions]struct { id: SessionId, change: Change } = undefined;
    var count: usize = 0;
    var it = engine.dirty.iterator();
    while (it.next()) |entry| : (count += 1) {
        std.debug.assert(count < batch.len); // the map is capped at the same bound
        batch[count] = .{ .id = entry.key_ptr.*, .change = entry.value_ptr.* };
    }
    engine.dirty.clearRetainingCapacity();
    const index = engine.index_dirty or engine.dirty_overflow;
    const index_facts = engine.index_facts;
    engine.index_dirty = false;
    engine.index_facts = .initEmpty();
    engine.dirty_overflow = false;

    // A dropped event must not leave a stale view, so an unset sink clears the batch and stops.
    if (ctx.isUndefined(engine.sink)) return false;
    engine.faulted = false;
    if (index) emitIndex(engine, ctx, index_facts);
    for (batch[0..count]) |entry| emitSession(engine, ctx, entry.id, entry.change);
    return engine.faulted;
}

fn emitIndex(engine: *Engine, ctx: Context, facts: FactSet) void {
    const ev = ctx.newObject();
    defer ctx.freeValue(ev);
    module.set(ctx, ev, "type", ctx.newString("index"));
    setFacts(ctx, ev, facts);
    call(engine, ctx, ev);
}

/// Name every fact the digest holds. A plugin reads the names; the view reads `kind` instead.
fn setFacts(ctx: Context, ev: Value, facts: FactSet) void {
    const names = ctx.newArray();
    var index: u32 = 0;
    var it = facts.iterator();
    while (it.next()) |fact| : (index += 1) {
        if (ctx.hasException()) break;
        ctx.setPropertyUint32(names, index, ctx.newString(@tagName(fact))) catch {};
    }
    module.set(ctx, ev, "facts", names);
}

fn emitSession(engine: *Engine, ctx: Context, sid: SessionId, change: Change) void {
    const ev = ctx.newObject();
    defer ctx.freeValue(ev);
    const hex = std.fmt.bytesToHex(sid.raw, .lower);
    module.set(ctx, ev, "type", ctx.newString("session"));
    module.set(ctx, ev, "session", ctx.newString(hex[0..]));
    module.set(ctx, ev, "kind", ctx.newString(change.kind()));
    setFacts(ctx, ev, change.facts);
    if (change.view == .message) {
        module.set(ctx, ev, "id", ctx.newFloat64(@floatFromInt(change.view.message.id)));
        if (change.view.message.part) |part| module.set(ctx, ev, "part", ctx.newFloat64(@floatFromInt(part)));
    }
    call(engine, ctx, ev);
}

/// Call the sink with a whole event. A full QuickJS heap during the build or a throwing sink faults the drain.
fn call(engine: *Engine, ctx: Context, ev: Value) void {
    if (!ctx.hasException()) {
        const result = ctx.call(engine.sink, quickjs.UNDEFINED, &.{ev});
        defer ctx.freeValue(result);
        if (!ctx.isException(result)) return;
    }
    // The fault takes the exception now, so the next event of the same drain still goes out.
    engine.faulted = true;
    Host.fromContext(ctx).noteFault();
}

const testing = std.testing;

test "a merge keeps every fact, even when a stronger kind resets the change" {
    const sid = SessionId.bytes([_]u8{0} ** 16);
    var change: Change = .of(.{ .method = .@"run.started", .params = .{ .run_started_data = .{
        .session_id = sid,
        .seq = 1,
        .run_id = 1,
        .kind = .turn,
        .config_rev = 0,
        .started_at_ms = 0,
    } } });
    try testing.expect(change.facts.contains(.@"run.started"));
    try testing.expectEqual(Change.View.quiet, change.view); // a run carries no transcript state

    // A removal resets the kind, and a plugin still needs to know the run started first.
    change.merge(.{ .view = .gone, .facts = FactSet.initOne(.@"session.removed") });
    try testing.expectEqual(Change.View.gone, change.view);
    try testing.expect(change.facts.contains(.@"run.started"));
    try testing.expect(change.facts.contains(.@"session.removed"));
}

test "a part event names its own message and never reloads the outline" {
    const sid = SessionId.bytes([_]u8{0} ** 16);
    const delta: Change = .of(.{ .method = .@"tool.output_delta", .params = .{ .tool_output_delta_data = .{
        .session_id = sid,
        .message_id = 7,
        .part_id = 1,
        .offset = 0,
        .delta = "out",
    } } });
    try testing.expectEqual(@as(proto.ids.MessageId, 7), delta.view.message.id);
    try testing.expectEqual(@as(?proto.ids.PartId, 1), delta.view.message.part);
    try testing.expectEqualStrings("active", delta.kind());

    const state: Change = .of(.{ .method = .@"tool.state_changed", .params = .{ .tool_state_changed_data = .{
        .session_id = sid,
        .message_id = 7,
        .part_id = 1,
        .state = .{ .running = .{ .started_at_ms = 0 } },
    } } });
    try testing.expectEqual(@as(proto.ids.MessageId, 7), state.view.message.id);
    try testing.expectEqual(@as(?proto.ids.PartId, 1), state.view.message.part);
}

test "the activity never reloads the transcript, and a part event outranks it" {
    const sid = SessionId.bytes([_]u8{0} ** 16);
    var change: Change = .of(.{ .method = .@"session.activity_changed", .params = .{ .session_activity_changed_data = .{
        .session_id = sid,
        .activity = .{ .state = .{ .idle = .{} }, .config = null, .queued = 0, .context_usage = .{ .input = 0, .output = 0, .reasoning = 0, .cache_read = 0, .cache_write = 0 }, .pending_compaction = null },
    } } });
    try testing.expectEqualStrings("quiet", change.kind());

    // A quiet event must not hold a later re-wrap back, and must not escalate one either.
    change.merge(.of(.{ .method = .@"message.part_delta", .params = .{ .message_part_delta_data = .{
        .session_id = sid,
        .message_id = 3,
        .part_id = 0,
        .offset = 0,
        .delta = "hi",
    } } }));
    try testing.expectEqual(@as(proto.ids.MessageId, 3), change.view.message.id);
    try testing.expectEqual(@as(?proto.ids.PartId, 0), change.view.message.part);
}

test "two parts widen to their message, and two messages widen to a reload" {
    var change: Change = .{ .view = .{ .message = .{ .id = 1, .part = 4 } } };
    change.merge(.{ .view = .{ .message = .{ .id = 1, .part = 4 } } });
    try testing.expectEqual(@as(?proto.ids.PartId, 4), change.view.message.part); // the same part stays one re-wrap

    change.merge(.{ .view = .{ .message = .{ .id = 1, .part = 5 } } });
    try testing.expectEqual(@as(proto.ids.MessageId, 1), change.view.message.id);
    try testing.expectEqual(@as(?proto.ids.PartId, null), change.view.message.part);

    change.merge(.{ .view = .{ .message = .{ .id = 2, .part = null } } });
    try testing.expectEqualStrings("reload", change.kind());
}

test "a throwing event sink faults once and leaves no pending exception" {
    const host = Host.create(testing.allocator);
    defer host.destroy();

    try host.evalModule(
        \\import { native } from "yuke:engine-native";
        \\globalThis.seen = 0;
        \\native.setEventSink(() => { globalThis.seen++; throw new Error("bad handler"); });
    , "sink.js");

    // Two dirty sessions: the drain must report the fault and still deliver both events.
    host.engine.markDirty(SessionId.bytes([_]u8{1} ** 16), .{ .view = .reload });
    host.engine.markDirty(SessionId.bytes([_]u8{2} ** 16), .{ .view = .reload });
    try testing.expect(drain(host.engine, host.ctx));
    try testing.expectEqual(@as(i32, 2), try host.evalInt("globalThis.seen"));

    // The next evaluation must not inherit the exception the sink left behind.
    try host.eval("globalThis.after = 41 + 1;", "after.js");
    try testing.expectEqual(@as(i32, 42), try host.evalInt("globalThis.after"));

    // A clean sink reports no fault.
    try host.evalModule(
        \\import { native } from "yuke:engine-native";
        \\native.setEventSink(() => {});
    , "ok.js");
    host.engine.markDirty(SessionId.bytes([_]u8{3} ** 16), .{ .view = .reload });
    try testing.expect(!drain(host.engine, host.ctx));
}
