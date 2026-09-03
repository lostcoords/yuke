//! The native `yuke:engine` module: the JavaScript seam onto the one in-process engine.
//! There is no transport and no replica. A view reads the engine's own session projection.
//!
//! Two rules hold this seam together. An event never re-enters JavaScript from an engine task;
//! the sink marks a session dirty and `drain` delivers it on the owner. And a text read is paged,
//! so one call copies a bounded number of bytes however large the message is.

const std = @import("std");
const quickjs = @import("quickjs");
const zio = @import("zio");
const proto = @import("proto");
const host_mod = @import("../host.zig");
const app = @import("../../app/app.zig");
const App = app.App;
const engine_call = @import("../../app/call.zig");
const turn = @import("../../engine/turn.zig");
const domain_session = @import("../../session/session.zig");
const Session = domain_session.Session;
const domain_draft = @import("../../session/draft.zig");

const Host = host_mod.Host;
const Context = quickjs.Context;
const Value = quickjs.Value;
const Module = Context.Module;
const SessionId = proto.ids.SessionId;

/// One text read copies at most this many bytes. A view asks again for the next page.
/// The inline text of a part is its first page, so a cut names where the second page starts.
/// A limit of zero asks for this default, so a caller that wants one page passes nothing.
pub const max_page_bytes: usize = 64 * 1024;
/// Bound the dirty set so a storm cannot grow it without limit. A full set marks everything dirty.
pub const max_dirty_sessions: usize = 256;
/// The default prompt uses the protocol string limit.
pub const max_system_prompt_bytes: usize = @intCast(proto.meta.limits.max_message_string_bytes);

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
    /// Set when the dirty set overflowed. `drain` then reports an index change, and the view
    /// rereads what it has open. A lost session event must never become a stale view.
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

    /// Stop event delivery before the state closes, so no later event reaches a freed context.
    /// Remove only this engine, so a detach never silences another frontend.
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

/// How one session changed since the last drain. A view redraws differently for each kind.
pub const Change = struct {
    /// The session is gone. This outranks every other kind.
    removed: bool = false,
    /// The outline changed, so the view must read it again.
    structural: bool = false,
    /// Only this message's text grew, so the view re-wraps one message.
    delta_message: ?u64 = null,

    /// Classify one event. A delta is the only cheap kind; everything else reloads the outline.
    fn of(note: proto.rpc.Notification) Change {
        return switch (note.method) {
            .@"session.removed" => .{ .removed = true },
            .@"message.part_delta" => .{ .delta_message = note.params.message_part_delta_data.message_id },
            else => .{ .structural = true },
        };
    }

    /// Fold a later event into an earlier one. The stronger kind wins, so no update is lost.
    fn merge(self: *Change, other: Change) void {
        if (other.removed) {
            self.* = .{ .removed = true };
            return;
        }
        if (self.removed) return;
        if (other.structural) {
            self.structural = true;
            self.delta_message = null;
            return;
        }
        if (self.structural) return;
        // Two deltas on different messages are not one re-wrap, so fall back to a reload.
        if (self.delta_message) |held| {
            if (other.delta_message != held) self.structural = true;
        } else self.delta_message = other.delta_message;
    }

    fn kind(self: Change) [:0]const u8 {
        if (self.removed) return "gone";
        if (self.structural or self.delta_message == null) return "reload";
        return "active";
    }
};

/// Read the session an event belongs to. An index event names no session.
fn sessionOf(note: proto.rpc.Notification) ?SessionId {
    return switch (note.params) {
        inline else => |payload| if (@hasField(@TypeOf(payload), "session_id")) payload.session_id else null,
    };
}

// ---------------------------------------------------------------- projections

/// Return the largest length at or below `limit` that ends on a UTF-8 character boundary.
fn utf8Floor(text: []const u8, limit: usize) usize {
    if (text.len <= limit) return text.len;
    var n = limit;
    while (n > 0 and (text[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

fn messageError(m: proto.message.Message) ?proto.message.MessageError {
    return switch (m) {
        .assistant => |a| a.@"error",
        else => null,
    };
}

/// Write the message ids and roles of one session. The list is small, so it is not paged.
fn writeOutline(w: *std.Io.Writer, s: *domain_session.Session) !void {
    try w.writeAll("{\"messages\":[");
    for (s.transcript.list.items, 0..) |entry, i| {
        if (i > 0) try w.writeByte(',');
        const role = switch (entry.message) {
            .user => "user",
            .compaction => "compaction",
            else => "assistant",
        };
        try w.print("{{\"id\":{d},\"type\":\"{s}\"", .{ entry.message.id(), role });
        if (messageError(entry.message)) |e| {
            try w.writeAll(",\"error\":{\"type\":");
            try std.json.Stringify.encodeJsonString(e.type, .{}, w);
            try w.writeAll(",\"message\":");
            try std.json.Stringify.encodeJsonString(e.message, .{}, w);
            try w.writeByte('}');
        }
        try w.writeByte('}');
    }
    try w.writeAll("],\"active\":");
    if (s.draft) |d| try w.print("{{\"id\":{d},\"type\":\"assistant\"}}", .{d.message_id}) else try w.writeAll("null");
    try w.writeByte('}');
}

/// A parts response bounds every string it writes, so one large tool result cannot grow it.
/// Every value the writer cut appears once in the part's `cut` list, which names the field and its whole size.
pub const max_inline_views: usize = 8;
pub const max_inline_diff_lines: usize = 200;
pub const max_inline_line_bytes: usize = 512;

/// The writer makes at most this many cut entries for one part, because its own caps bound them.
const max_cuts: usize = 2 * max_inline_views + 8;

/// One value the projection cut. `field` is the address, and `size` is bytes for a string and items for a collection.
const Cut = struct {
    field: Field,
    /// The view list this cut belongs to, and empty for a field outside a view list.
    list: []const u8 = "",
    /// The position in the view list, and zero for a field outside a view list.
    index: u32 = 0,
    size: u64,
    /// Where the inline prefix stopped, so a reader resumes there and keeps what it holds. Null for a collection.
    next: ?u64 = null,

    /// A field of the projection, named the way `partText` addresses it.
    const Field = enum {
        text,
        arguments,
        output,
        @"error",
        view_text,
        view_diff,
        view_count,

        /// Report whether this field counts items instead of bytes.
        fn counts(self: Field) bool {
            return switch (self) {
                .view_diff, .view_count => true,
                else => false,
            };
        }
    };
};

/// The cuts of one part, collected while the part is written and emitted before its closing brace.
const Cuts = struct {
    items: [max_cuts]Cut = undefined,
    len: usize = 0,

    /// Record one cut. The caps of this writer bound the count, so an overflow is a bug here.
    fn add(self: *Cuts, cut: Cut) void {
        std.debug.assert(self.len < max_cuts); // the writer's own caps bound every entry
        std.debug.assert(cut.size > 0); // a cut value always has a whole size
        std.debug.assert(cut.field.counts() == (cut.next == null)); // only a string cut resumes
        self.items[self.len] = cut;
        self.len += 1;
    }

    /// Write `,"cut":[...]`, or nothing when the part is whole.
    fn write(self: *const Cuts, w: *std.Io.Writer) !void {
        if (self.len == 0) return;
        try w.writeAll(",\"cut\":[");
        for (self.items[0..self.len], 0..) |c, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"field\":\"");
            switch (c.field) {
                .text => try w.writeAll("text"),
                .arguments => try w.writeAll("arguments"),
                .output => try w.writeAll("output"),
                .@"error" => try w.writeAll("error"),
                .view_count => try w.writeAll(c.list),
                .view_text => try w.print("{s}.{d}.text", .{ c.list, c.index }),
                .view_diff => try w.print("{s}.{d}.diff", .{ c.list, c.index }),
            }
            try w.print("\",\"{s}\":{d}", .{ if (c.field.counts()) "total" else "bytes", c.size });
            if (c.next) |next| try w.print(",\"next\":{d}", .{next});
            try w.writeByte('}');
        }
        try w.writeByte(']');
    }
};

/// Write `"name":"..."` with the text cut on a character boundary. Record the whole size when cut.
fn writeCapped(w: *std.Io.Writer, cuts: *Cuts, field: Cut.Field, list: []const u8, index: u32, name: []const u8, text: []const u8) !void {
    const end = utf8Floor(text, max_page_bytes);
    try w.print("\"{s}\":", .{name});
    try std.json.Stringify.encodeJsonString(text[0..end], .{}, w);
    if (end < text.len) cuts.add(.{ .field = field, .list = list, .index = index, .size = text.len, .next = end });
}

/// Write one part. Every string it holds is bounded, whatever the tool produced.
fn writePart(w: *std.Io.Writer, p: proto.message.AssistantPart) !void {
    var cuts: Cuts = .{};
    switch (p) {
        .text => |t| try writeTextPart(w, &cuts, "text", t.id, t.text),
        .reasoning => |r| try writeTextPart(w, &cuts, "reasoning", r.id, r.text),
        .redacted_reasoning => |r| try w.print("{{\"type\":\"redacted_reasoning\",\"id\":{d}}}", .{r.id}),
        .tool => |t| try writeToolPart(w, &cuts, t),
    }
}

/// Write a text-bearing part. A cut text names itself in `cut`, so a view knows to page the rest.
fn writeTextPart(w: *std.Io.Writer, cuts: *Cuts, kind: []const u8, id: u64, text: []const u8) !void {
    const end = utf8Floor(text, max_page_bytes);
    try w.print("{{\"type\":\"{s}\",\"id\":{d},\"text\":", .{ kind, id });
    try std.json.Stringify.encodeJsonString(text[0..end], .{}, w);
    if (end < text.len) cuts.add(.{ .field = .text, .size = text.len, .next = end });
    try cuts.write(w);
    try w.writeByte('}');
}

/// Write a tool part field by field. A generic encode here would copy a whole tool result.
fn writeToolPart(w: *std.Io.Writer, cuts: *Cuts, t: proto.message.ToolPart) !void {
    try w.print("{{\"type\":\"tool\",\"id\":{d},\"name\":", .{t.id});
    try std.json.Stringify.encodeJsonString(t.name, .{}, w);
    if (t.call_id) |call_id| {
        try w.writeAll(",\"call_id\":");
        try std.json.Stringify.encodeJsonString(call_id, .{}, w);
    }
    try w.writeByte(',');
    try writeCapped(w, cuts, .arguments, "", 0, "arguments", t.arguments);
    if (t.input_view) |views| {
        try w.writeAll(",\"input_view\":");
        try writeViews(w, cuts, "input_view", views);
    }
    try w.writeAll(",\"state\":");
    try writeToolState(w, cuts, t.state);
    try cuts.write(w);
    try w.writeByte('}');
}

fn writeToolState(w: *std.Io.Writer, cuts: *Cuts, state: proto.tool.ToolState) !void {
    switch (state) {
        .pending => try w.writeAll("{\"type\":\"pending\"}"),
        .canceled => |c| {
            try w.writeAll("{\"type\":\"canceled\"");
            if (c.duration_ms) |ms| try w.print(",\"duration_ms\":{d}", .{ms});
            try w.writeByte('}');
        },
        .running => |r| {
            try w.print("{{\"type\":\"running\",\"started_at_ms\":{d}", .{r.started_at_ms});
            if (r.output) |out| {
                try w.writeByte(',');
                try writeCapped(w, cuts, .output, "", 0, "output", out);
            }
            try w.writeByte('}');
        },
        .completed => |c| {
            try w.print("{{\"type\":\"completed\",\"duration_ms\":{d},", .{c.duration_ms});
            try writeCapped(w, cuts, .output, "", 0, "output", c.output);
            if (c.view) |views| {
                try w.writeAll(",\"view\":");
                try writeViews(w, cuts, "view", views);
            }
            try w.writeByte('}');
        },
        .@"error" => |e| {
            try w.print("{{\"type\":\"error\",\"duration_ms\":{d},", .{e.duration_ms});
            try writeCapped(w, cuts, .@"error", "", 0, "error", e.@"error");
            if (e.view) |views| {
                try w.writeAll(",\"view\":");
                try writeViews(w, cuts, "view", views);
            }
            try w.writeByte('}');
        },
    }
}

/// Write at most `max_inline_views` views. A dropped view is recorded, so a row can say how many it hides.
fn writeViews(w: *std.Io.Writer, cuts: *Cuts, list: []const u8, views: []const proto.view.View) !void {
    try w.writeByte('[');
    const shown = @min(views.len, max_inline_views);
    for (views[0..shown], 0..) |v, i| {
        if (i > 0) try w.writeByte(',');
        try writeView(w, cuts, list, @intCast(i), v);
    }
    try w.writeByte(']');
    if (shown < views.len) cuts.add(.{ .field = .view_count, .list = list, .size = views.len });
}

fn writeView(w: *std.Io.Writer, cuts: *Cuts, list: []const u8, index: u32, v: proto.view.View) !void {
    switch (v) {
        .text => |t| {
            try w.writeAll("{\"type\":\"text\",");
            try writeCapped(w, cuts, .view_text, list, index, "text", t.text);
            if (t.language) |lang| {
                try w.writeAll(",\"language\":");
                try std.json.Stringify.encodeJsonString(lang, .{}, w);
            }
            try w.writeByte('}');
        },
        .markdown => |t| {
            try w.writeAll("{\"type\":\"markdown\",");
            try writeCapped(w, cuts, .view_text, list, index, "text", t.text);
            try w.writeByte('}');
        },
        .json => |t| {
            try w.writeAll("{\"type\":\"json\",");
            try writeCapped(w, cuts, .view_text, list, index, "text", t.text);
            try w.writeByte('}');
        },
        // An image view names a blob; it carries no inline bytes.
        .image => |t| try std.json.Stringify.value(v: {
            break :v .{ .type = "image", .source = t.source, .alt = t.alt };
        }, .{ .emit_null_optional_fields = false }, w),
        .diff => |d| try writeDiff(w, cuts, list, index, d),
    }
}

/// Write a diff with a bounded line count. A transcript shows a preview, never a whole patch.
fn writeDiff(w: *std.Io.Writer, cuts: *Cuts, list: []const u8, index: u32, d: proto.view.ViewDiff) !void {
    var budget: usize = max_inline_diff_lines;
    var total: u64 = 0;
    var shortened: u64 = 0;
    try w.writeAll("{\"type\":\"diff\",\"files\":[");
    for (d.files, 0..) |file, fi| {
        if (fi > 0) try w.writeByte(',');
        try w.writeAll("{\"path\":");
        try std.json.Stringify.encodeJsonString(file.path, .{}, w);
        if (file.old_path) |old| {
            try w.writeAll(",\"old_path\":");
            try std.json.Stringify.encodeJsonString(old, .{}, w);
        }
        try w.writeAll(",\"hunks\":[");
        for (file.hunks, 0..) |hunk, hi| {
            if (hi > 0) try w.writeByte(',');
            try w.print("{{\"old_start\":{d},\"old_lines\":{d},\"new_start\":{d},\"new_lines\":{d},\"lines\":[", .{
                hunk.old_start, hunk.old_lines, hunk.new_start, hunk.new_lines,
            });
            total += hunk.lines.len;
            const shown = @min(hunk.lines.len, budget);
            for (hunk.lines[0..shown], 0..) |line, li| {
                if (li > 0) try w.writeByte(',');
                const end = utf8Floor(line, max_inline_line_bytes);
                if (end < line.len) shortened += 1;
                try std.json.Stringify.encodeJsonString(line[0..end], .{}, w);
            }
            budget -= shown;
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
    // A dropped line and a shortened line both abbreviate the diff, and a preview reports the whole count either way.
    if (total > max_inline_diff_lines or shortened > 0) {
        cuts.add(.{ .field = .view_diff, .list = list, .index = index, .size = total });
    }
}

fn writeMessageParts(w: *std.Io.Writer, s: *domain_session.Session, mid: u64) !void {
    try w.writeByte('[');
    if (s.draft) |*d| if (d.message_id == mid) {
        for (d.parts.items, 0..) |*p, i| {
            if (i > 0) try w.writeByte(',');
            try writePart(w, domain_draft.partToWire(p));
        }
        return w.writeByte(']');
    };
    for (s.transcript.list.items) |entry| {
        if (entry.message.id() != mid) continue;
        switch (entry.message) {
            .assistant => |a| for (a.content, 0..) |p, i| {
                if (i > 0) try w.writeByte(',');
                try writePart(w, p);
            },
            else => {},
        }
        return w.writeByte(']');
    }
    try w.writeByte(']');
}

/// Call `each` with the text of every text-bearing part of one message, in order.
fn forEachText(
    s: *domain_session.Session,
    mid: u64,
    ctx: anytype,
    comptime each: fn (@TypeOf(ctx), []const u8) void,
) void {
    if (s.draft) |*d| if (d.message_id == mid) {
        for (d.parts.items) |*p| switch (domain_draft.partToWire(p)) {
            .text => |t| each(ctx, t.text),
            else => {},
        };
        return;
    };
    for (s.transcript.list.items) |entry| {
        if (entry.message.id() != mid) continue;
        switch (entry.message) {
            .user => |u| for (u.content) |c| switch (c) {
                .text => |t| each(ctx, t.text),
                else => {},
            },
            .assistant => |a| for (a.content) |p| switch (p) {
                .text => |t| each(ctx, t.text),
                else => {},
            },
            .compaction => |c| each(ctx, c.summary),
        }
        return;
    }
}

/// Copy one window of a message's concatenated text. It walks the parts and copies only the window,
/// so a large message costs a walk and a bounded copy, never a full materialization.
const TextWindow = struct {
    want_from: usize,
    want_to: usize,
    seen: usize = 0,
    out: *std.Io.Writer,
    total: usize = 0,
    failed: bool = false,

    fn take(self: *TextWindow, text: []const u8) void {
        self.total += text.len;
        const start = self.seen;
        self.seen += text.len;
        if (self.failed or self.seen <= self.want_from or start >= self.want_to) return;
        const from = if (self.want_from > start) self.want_from - start else 0;
        const to = @min(text.len, self.want_to - start);
        std.debug.assert(from <= to and to <= text.len); // the window never leaves the part
        self.out.writeAll(text[from..to]) catch {
            self.failed = true;
        };
    }
};

/// The principal text of one assistant part. A tool part answers with what a transcript row shows.
/// Resolve one `cut` address of a part to its whole text. `field` comes from JavaScript, so an unknown address answers null.
fn assistantPartText(p: proto.message.AssistantPart, part_id: u64, field: []const u8) ?[]const u8 {
    return switch (p) {
        .text => |t| if (t.id == part_id and std.mem.eql(u8, field, "text")) t.text else null,
        .reasoning => |r| if (r.id == part_id and std.mem.eql(u8, field, "text")) r.text else null,
        .redacted_reasoning => null,
        .tool => |t| if (t.id != part_id) null else toolFieldText(t, field),
    };
}

/// Resolve one field of a tool part. The names match what `Cuts` writes, so a reader passes an address back unchanged.
fn toolFieldText(t: proto.message.ToolPart, field: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, field, "arguments")) return t.arguments;
    if (std.mem.eql(u8, field, "output")) return switch (t.state) {
        .completed => |c| c.output,
        .running => |r| r.output,
        else => null,
    };
    if (std.mem.eql(u8, field, "error")) return switch (t.state) {
        .@"error" => |e| e.@"error",
        else => null,
    };
    if (viewTextIndex(field, "input_view")) |i| return viewText(t.input_view, i);
    if (viewTextIndex(field, "view")) |i| return viewText(switch (t.state) {
        .completed => |c| c.view,
        .@"error" => |e| e.view,
        else => null,
    }, i);
    return null;
}

/// Read `<list>.<index>.text` and answer the index. A field of another shape answers null.
fn viewTextIndex(field: []const u8, list: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, field, list)) return null;
    const rest = field[list.len..];
    if (rest.len == 0 or rest[0] != '.') return null;
    const dot = std.mem.indexOfScalar(u8, rest[1..], '.') orelse return null;
    if (!std.mem.eql(u8, rest[1 + dot + 1 ..], "text")) return null;
    return std.fmt.parseInt(u32, rest[1 .. 1 + dot], 10) catch null;
}

/// The text of one view, or null when the index is past the list or the view holds no text.
fn viewText(views: ?[]const proto.view.View, index: u32) ?[]const u8 {
    const list = views orelse return null;
    if (index >= list.len) return null;
    return switch (list[index]) {
        .text => |t| t.text,
        .markdown => |t| t.text,
        .json => |t| t.text,
        else => null,
    };
}

/// Find the text of one part, in the draft or the committed window.
fn partTextOf(s: *domain_session.Session, mid: u64, part_id: u64, field: []const u8) ?[]const u8 {
    if (s.draft) |*d| if (d.message_id == mid) {
        for (d.parts.items) |*p| {
            if (assistantPartText(domain_draft.partToWire(p), part_id, field)) |text| return text;
        }
        return null;
    };
    for (s.transcript.list.items) |entry| {
        if (entry.message.id() != mid) continue;
        switch (entry.message) {
            .assistant => |a| for (a.content) |p| {
                if (assistantPartText(p, part_id, field)) |text| return text;
            },
            .user => |u| for (u.content) |c| switch (c) {
                .text => |t| return t.text,
                else => {},
            },
            .compaction => |c| return c.summary,
        }
        return null;
    }
    return null;
}

// ---------------------------------------------------------------- javascript seam

fn sidArg(ctx: Context, args: []const Value, idx: usize) ?SessionId {
    if (args.len <= idx) return null;
    const text = ctx.toCStringLen(args[idx]) catch return null;
    defer ctx.freeCString(text.ptr);
    if (text.len != SessionId.byte_len * 2) return null;
    var raw: [SessionId.byte_len]u8 = undefined;
    _ = std.fmt.hexToBytes(&raw, text) catch return null;
    return SessionId.bytes(raw);
}

/// Resolve a page limit. Absent or zero means one default page, and nothing exceeds the cap.
fn pageLimit(raw: ?u64) usize {
    const want = raw orelse 0;
    if (want == 0) return max_page_bytes;
    return @intCast(@min(want, max_page_bytes));
}

fn u64Arg(ctx: Context, args: []const Value, idx: usize) ?u64 {
    if (args.len <= idx) return null;
    const n = ctx.toFloat64(args[idx]) catch return null;
    if (!(n >= 0)) return null; // a NaN fails this test, which is what we want
    return std.math.lossyCast(u64, n);
}

/// Resolve the live runtime a view reads. A view that never opened the session gets null.
fn runtimeArg(engine: *Engine, ctx: Context, args: []const Value) ?*Session {
    const runtime = engine.runtime orelse return null;
    const sid = sidArg(ctx, args, 0) orelse return null;
    return runtime.engine.sessions.get(sid);
}

/// Write a projection into a QuickJS string. `fallback` answers a session the view cannot read.
fn projectString(
    engine: *Engine,
    ctx: Context,
    args: []const Value,
    fallback: [:0]const u8,
    comptime write: fn (*std.Io.Writer, *domain_session.Session) anyerror!void,
) Value {
    const rt = runtimeArg(engine, ctx, args) orelse return ctx.newString(fallback);
    var aw: std.Io.Writer.Allocating = .init(engine.gpa);
    defer aw.deinit();
    write(&aw.writer, rt) catch return ctx.newString(fallback);
    return ctx.newString(aw.written());
}

fn jsSetEventSink(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    ctx.freeValue(engine.sink);
    engine.sink = if (args.len > 0) ctx.dupValue(args[0]) else quickjs.UNDEFINED;
    return quickjs.UNDEFINED;
}

/// Open a view onto one session. The pin keeps the runtime alive while a pane shows it.
fn jsSessionOpen(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const runtime = engine.runtime orelse return ctx.newBool(false);
    const sid = sidArg(ctx, args, 0) orelse return ctx.newBool(false);
    const rt = runtime.engine.activate(sid) catch return ctx.newBool(false);
    rt.pin();
    // The durable queue of this session restarts here, in the one process that looks at it.
    turn.resumeSession(&runtime.engine, rt) catch |err| {
        std.log.warn("cannot resume session: {t}", .{err});
    };
    return ctx.newBool(true);
}

/// Close one view. The runtime may evict after the last pane leaves.
fn jsSessionClose(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const runtime = engine.runtime orelse return quickjs.UNDEFINED;
    const sid = sidArg(ctx, args, 0) orelse return quickjs.UNDEFINED;
    const rt = runtime.engine.sessions.get(sid) orelse return quickjs.UNDEFINED;
    rt.unpin();
    runtime.engine.sessions.evictIfIdle(sid);
    return quickjs.UNDEFINED;
}

fn jsSessionOutline(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    return projectString(engine, ctx, args, "null", writeOutline);
}

fn jsSessionParts(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const rt = runtimeArg(engine, ctx, args) orelse return ctx.newString("[]");
    const mid = u64Arg(ctx, args, 1) orelse return ctx.newString("[]");
    var aw: std.Io.Writer.Allocating = .init(engine.gpa);
    defer aw.deinit();
    writeMessageParts(&aw.writer, rt, mid) catch return ctx.newString("[]");
    return ctx.newString(aw.written());
}

/// One page of a message's whole text: `{"text":...,"next":N|null,"bytes":T}`.
/// The walk visits every part but copies only the window, so cost follows the page, not the message.
fn jsSessionText(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const empty = "{\"text\":\"\",\"next\":null,\"bytes\":0}";
    const rt = runtimeArg(engine, ctx, args) orelse return ctx.newString(empty);
    const mid = u64Arg(ctx, args, 1) orelse return ctx.newString(empty);
    const offset: usize = @intCast(u64Arg(ctx, args, 2) orelse 0);
    const want = pageLimit(u64Arg(ctx, args, 3));

    var raw: std.Io.Writer.Allocating = .init(engine.gpa);
    defer raw.deinit();
    var window: TextWindow = .{ .want_from = offset, .want_to = offset +| want, .out = &raw.writer };
    forEachText(rt, mid, &window, TextWindow.take);
    if (window.failed) return ctx.newString(empty);

    // The concatenation is valid UTF-8, so flooring the copied window never splits a character.
    const cut = utf8Floor(raw.written(), raw.written().len);
    var aw: std.Io.Writer.Allocating = .init(engine.gpa);
    defer aw.deinit();
    aw.writer.writeAll("{\"text\":") catch return ctx.newString(empty);
    std.json.Stringify.encodeJsonString(raw.written()[0..cut], .{}, &aw.writer) catch return ctx.newString(empty);
    const next = offset + cut;
    if (next < window.total)
        aw.writer.print(",\"next\":{d},\"bytes\":{d}}}", .{ next, window.total }) catch return ctx.newString(empty)
    else
        aw.writer.print(",\"next\":null,\"bytes\":{d}}}", .{window.total}) catch return ctx.newString(empty);
    return ctx.newString(aw.written());
}

/// One page of one field of a part: `{"text":...,"next":N|null}`. `field` is the address a `cut` entry names.
fn jsPartText(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const empty = "{\"text\":\"\",\"next\":null}";
    const rt = runtimeArg(engine, ctx, args) orelse return ctx.newString(empty);
    const mid = u64Arg(ctx, args, 1) orelse return ctx.newString(empty);
    const part_id = u64Arg(ctx, args, 2) orelse return ctx.newString(empty);
    if (args.len <= 3) return ctx.newString(empty);
    const field = ctx.toCStringLen(args[3]) catch return ctx.newString(empty);
    defer ctx.freeCString(field.ptr);
    const offset = u64Arg(ctx, args, 4) orelse 0;
    const want = pageLimit(u64Arg(ctx, args, 5));

    const text = partTextOf(rt, mid, part_id, field) orelse return ctx.newString(empty);
    if (offset >= text.len) return ctx.newString(empty);
    const start: usize = @intCast(offset);
    const cut = start + utf8Floor(text[start..], want);
    std.debug.assert(cut >= start and cut <= text.len); // the floor never leaves the slice

    var aw: std.Io.Writer.Allocating = .init(engine.gpa);
    defer aw.deinit();
    aw.writer.writeAll("{\"text\":") catch return ctx.newString(empty);
    std.json.Stringify.encodeJsonString(text[start..cut], .{}, &aw.writer) catch return ctx.newString(empty);
    if (cut < text.len)
        aw.writer.print(",\"next\":{d}}}", .{cut}) catch return ctx.newString(empty)
    else
        aw.writer.writeAll(",\"next\":null}") catch return ctx.newString(empty);
    return ctx.newString(aw.written());
}

/// Run one command and answer with its result JSON. A refusal throws with its wire code.
/// There is no envelope: the caller names a method, and the engine answers with the result itself.
fn jsRequest(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const runtime = engine.runtime orelse return ctx.throwPlainError("the engine is not ready");
    if (args.len < 2) return ctx.throwPlainError("a call needs a method and parameters");

    const method = ctx.toCStringLen(args[0]) catch return ctx.throwPlainError("the method must be a string");
    defer ctx.freeCString(method.ptr);
    const params = ctx.toCStringLen(args[1]) catch return ctx.throwPlainError("the parameters must be JSON");
    defer ctx.freeCString(params.ptr);

    var arena_state: std.heap.ArenaAllocator = .init(engine.gpa);
    defer arena_state.deinit();

    var aw: std.Io.Writer.Allocating = .init(engine.gpa);
    defer aw.deinit();

    const failure = engine_call.call(runtime, arena_state.allocator(), method, params, &aw.writer) catch
        return ctx.throwPlainError("internal error");
    if (failure) |refused| return throwFailure(ctx, refused);
    return ctx.newString(aw.written());
}

/// Set the default prompt for sessions created without an explicit prompt.
fn jsSetDefaultSystemPrompt(ctx: Context, _: Value, args: []const Value) Value {
    const engine = Host.fromContext(ctx).engine;
    const runtime = engine.runtime orelse return ctx.throwPlainError("the engine is not ready");
    if (args.len < 1 or (!ctx.isString(args[0]) and !ctx.isNull(args[0])))
        return ctx.throwTypeError("the default system prompt must be a string or null");
    if (ctx.isNull(args[0])) {
        runtime.engine.setDefaultSystemPrompt(null) catch return ctx.throwOutOfMemory();
        return quickjs.UNDEFINED;
    }
    const prompt = ctx.toCStringLen(args[0]) catch return ctx.throwOutOfMemory();
    defer ctx.freeCString(prompt.ptr);
    if (prompt.len > max_system_prompt_bytes)
        return ctx.throwTypeError("the default system prompt exceeds the protocol string limit");
    runtime.engine.setDefaultSystemPrompt(prompt) catch return ctx.throwOutOfMemory();
    return quickjs.UNDEFINED;
}

/// Raise a refusal as a JavaScript error that carries its wire code, so a view can branch on it.
fn throwFailure(ctx: Context, failure: engine_call.Failure) Value {
    const err = ctx.newError();
    if (ctx.isException(err)) return err;
    ctx.setPropertyStr(err, "message", ctx.newString(failure.message)) catch return err;
    ctx.setPropertyStr(err, "code", ctx.newString(@tagName(failure.code))) catch return err;
    return ctx.throw(err);
}

/// Deliver the sessions that changed since the last call. The owner calls this between frames,
/// so an engine task never re-enters JavaScript. Return true when an event sink threw.
pub fn drain(engine: *Engine, ctx: Context) bool {
    // Take the batch before the first callback. A sink callback may run a request, that request
    // publishes an event, and that event writes the dirty map. A live iterator would not survive it.
    var batch: [max_dirty_sessions]struct { id: SessionId, change: Change } = undefined;
    var count: usize = 0;
    var it = engine.dirty.iterator();
    while (it.next()) |entry| : (count += 1) {
        std.debug.assert(count < batch.len); // the map is capped at the same bound
        batch[count] = .{ .id = entry.key_ptr.*, .change = entry.value_ptr.* };
    }
    engine.dirty.clearRetainingCapacity();
    const index = engine.index_dirty or engine.dirty_overflow;
    engine.index_dirty = false;
    engine.dirty_overflow = false;

    // A dropped event must not leave a stale view, so an unset sink clears the batch and stops.
    if (ctx.isUndefined(engine.sink)) return false;
    engine.faulted = false;
    if (index) emitIndex(engine, ctx);
    for (batch[0..count]) |entry| emitSession(engine, ctx, entry.id, entry.change);
    // A throwing sink leaves a pending exception. Capture and clear it, as a key press does.
    if (engine.faulted) Host.fromContext(ctx).noteFault();
    return engine.faulted;
}

fn emitIndex(engine: *Engine, ctx: Context) void {
    const ev = ctx.newObject();
    if (ctx.isException(ev)) return;
    defer ctx.freeValue(ev);
    ctx.setPropertyStr(ev, "type", ctx.newString("index")) catch return;
    if (call(engine, ctx, ev)) engine.faulted = true;
}

fn emitSession(engine: *Engine, ctx: Context, sid: SessionId, change: Change) void {
    const ev = ctx.newObject();
    if (ctx.isException(ev)) return;
    defer ctx.freeValue(ev);
    const hex = std.fmt.bytesToHex(sid.raw, .lower);
    ctx.setPropertyStr(ev, "type", ctx.newString("session")) catch return;
    ctx.setPropertyStr(ev, "session", ctx.newString(hex[0..])) catch return;
    ctx.setPropertyStr(ev, "kind", ctx.newString(change.kind())) catch return;
    if (change.delta_message) |mid| {
        if (!change.structural and !change.removed)
            ctx.setPropertyStr(ev, "id", ctx.newFloat64(@floatFromInt(mid))) catch return;
    }
    if (call(engine, ctx, ev)) engine.faulted = true;
}

/// Call the sink and answer whether it threw. A pending exception would change the meaning of
/// the next JavaScript call, so the caller clears it and reports the fault.
fn call(engine: *Engine, ctx: Context, ev: Value) bool {
    const result = ctx.call(engine.sink, quickjs.UNDEFINED, &.{ev});
    defer ctx.freeValue(result);
    return ctx.isException(result);
}

pub fn install(host: *Host) error{OutOfMemory}!void {
    std.debug.assert(host.phase == .open);
    const m = host.ctx.newModule("yuke:engine-native", init) orelse return error.OutOfMemory;
    host.ctx.addModuleExport(m, "native") catch return error.OutOfMemory;
}

fn init(ctx: Context, m: Module) c_int {
    std.debug.assert(Host.fromContext(ctx).phase == .open);
    const native = ctx.newObject();
    if (ctx.isException(native)) return -1;
    if (bindAll(ctx, native) != 0) {
        ctx.freeValue(native);
        return -1;
    }
    // `setModuleExport` consumes `native` on success and on failure, so the catch must not free it.
    ctx.setModuleExport(m, "native", native) catch return -1;
    return 0;
}

fn bindAll(ctx: Context, native: Value) c_int {
    bind(ctx, native, "setDefaultSystemPrompt", 1, jsSetDefaultSystemPrompt) catch return -1;
    bind(ctx, native, "setEventSink", 1, jsSetEventSink) catch return -1;
    bind(ctx, native, "request", 2, jsRequest) catch return -1;
    bind(ctx, native, "sessionOpen", 1, jsSessionOpen) catch return -1;
    bind(ctx, native, "sessionClose", 1, jsSessionClose) catch return -1;
    bind(ctx, native, "sessionOutline", 1, jsSessionOutline) catch return -1;
    bind(ctx, native, "sessionParts", 2, jsSessionParts) catch return -1;
    bind(ctx, native, "sessionText", 4, jsSessionText) catch return -1;
    bind(ctx, native, "partText", 6, jsPartText) catch return -1;
    return 0;
}

fn bind(ctx: Context, obj: Value, name: [*:0]const u8, length: c_int, comptime fn_: fn (Context, Value, []const Value) Value) !void {
    try ctx.setPropertyStr(obj, name, ctx.newFunction(name, length, fn_));
}

const testing = std.testing;

test "utf8Floor never cuts a character in half" {
    try testing.expectEqual(@as(usize, 5), utf8Floor("hello", 64)); // shorter than the limit
    try testing.expectEqual(@as(usize, 3), utf8Floor("hello", 3)); // an ASCII cut is exact
    // "é" is two bytes, so a cut at 1 walks back to 0.
    try testing.expectEqual(@as(usize, 0), utf8Floor("é", 1));
    try testing.expectEqual(@as(usize, 2), utf8Floor("é", 2));
    // "aé" cuts back to 1 rather than splitting the second character.
    try testing.expectEqual(@as(usize, 1), utf8Floor("aé", 2));
    // A four-byte emoji walks back to the character start from every interior offset.
    try testing.expectEqual(@as(usize, 0), utf8Floor("😀", 1));
    try testing.expectEqual(@as(usize, 0), utf8Floor("😀", 3));
    try testing.expectEqual(@as(usize, 4), utf8Floor("😀", 4));
}

test "a request reaches a command and answers with its result" {
    const database = @import("../../store/store.zig");
    const provider = @import("../../provider/provider.zig");

    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    var canned = provider.transport.CannedTransport{ .bytes = provider.transport.canned_reply };
    var runtime: app.App = undefined;
    try runtime.initTest(testing.allocator, rt.io(), try database.Database.openTest(), &env, canned.transport());
    defer runtime.logins.deinit();
    defer runtime.store.deinit();
    defer runtime.db.deinit();
    defer runtime.engine.close();
    defer runtime.catalog_client.deinit();

    const host = try Host.create(testing.allocator);
    defer host.destroy();

    // With no engine, a view read answers its empty projection and a request refuses.
    try host.evalModule(
        \\import { native } from "yuke:engine-native";
        \\let threw = 0;
        \\try { native.request("catalog.list", "{}"); } catch { threw = 1; }
        \\globalThis.detached = threw;
    , "detached.js");
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.detached"));

    // With the engine attached, the same call reaches `commands.catalogList`.
    host.engine.attach(&runtime);
    try host.evalModule(
        \\import { native } from "yuke:engine-native";
        \\const r = JSON.parse(native.request("catalog.list", "{}"));
        \\globalThis.ok = r && Array.isArray(r.models) ? 1 : 0;
    , "attached.js");
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.ok"));

    // A command with real parameters must decode them, not fall back to an empty object.
    try host.evalModule(
        \\import { native } from "yuke:engine-native";
        \\const r = JSON.parse(native.request("session.create", JSON.stringify({ workspace_path: "/tmp/yuke-probe" })));
        \\globalThis.created = r && r.session ? 1 : 0;
        \\globalThis.sid = r && r.session ? r.session.id : "";
    , "create.js");
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.created"));

    // The client shape of an input must decode. A wrong shape refuses every message a person sends.
    try host.evalModule(
        \\import { client } from "yuke:client";
        \\globalThis.sent = 0;
        \\client.sessionSendInput(globalThis.sid, "probe").then(() => { globalThis.sent = 1; }, () => { globalThis.sent = 2; });
    , "send.js");
    try host.drainJobs();
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.sent"));

    // The text a person typed must come back. A default limit reads one page, never zero bytes.
    try host.evalModule(
        \\import { client } from "yuke:client";
        \\const o = client.sessionOutline(globalThis.sid);
        \\const first = o && o.messages.length ? o.messages[0].id : 0;
        \\globalThis.text = first ? client.sessionText(globalThis.sid, first) : "";
        \\globalThis.len = globalThis.text.length;
    , "text.js");
    try testing.expectEqual(@as(i32, 5), try host.evalInt("globalThis.len")); // "probe"

    // A refusal reaches JavaScript as an error that names its wire code.
    try host.evalModule(
        \\import { native } from "yuke:engine-native";
        \\globalThis.code = "";
        \\try { native.request("session.config", JSON.stringify({ session_id: "00".repeat(16), config_rev: 1 })); }
        \\catch (e) { globalThis.code = e.code || ""; }
        \\globalThis.isUnknown = globalThis.code === "unknown_session" ? 1 : 0;
    , "refuse.js");
    try testing.expectEqual(@as(i32, 1), try host.evalInt("globalThis.isUnknown"));
    host.engine.detach();
}

test "a huge tool result projects into a bounded parts response" {
    const gpa = testing.allocator;
    const sid = SessionId.bytes([_]u8{3} ** 16);
    var sess = domain_session.Session.init(gpa, sid);
    defer sess.deinit();

    // One megabyte of output is what the protocol permits for a tool stream.
    const huge = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(huge);
    @memset(huge, 'x');

    const lines = [_][]const u8{huge};
    const hunks = [_]proto.view.DiffHunk{.{ .old_start = 1, .old_lines = 1, .new_start = 1, .new_lines = 1, .lines = &lines }};
    const files = [_]proto.view.DiffFile{.{ .path = "a.zig", .hunks = &hunks }};
    const views = [_]proto.view.View{.{ .diff = .{ .files = &files } }};

    const content = [_]proto.message.AssistantPart{.{ .tool = .{
        .id = 0,
        .name = "exec",
        .arguments = huge,
        .state = .{ .completed = .{ .output = huge, .view = &views, .duration_ms = 5 } },
    } }};
    const messages = [_]proto.message.Message{.{ .assistant = .{
        .id = 1,
        .run_id = 1,
        .config_rev = 0,
        .agent = "claude",
        .content = &content,
        .time = .{ .created_at_ms = 1 },
    } }};
    try sess.installSnapshot(.{ .base_seq = 1, .finalized_message_id = 1, .messages = &messages, .has_more = false });

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeMessageParts(&aw.writer, &sess, 1);

    // Three megabytes of source must not become a three-megabyte projection. One page per string bounds it.
    try testing.expect(aw.written().len < 4 * max_page_bytes);
    // The response still says how large the output really is, so a view can page it.
    try testing.expect(std.mem.indexOf(u8, aw.written(), "{\"field\":\"output\",\"bytes\":1048576,\"next\":65536}") != null);
    // The one diff line is far over the line cap, and the response says so instead of eliding in silence.
    try testing.expect(std.mem.indexOf(u8, aw.written(), "{\"field\":\"view.0.diff\",\"total\":1}") != null);

    // `partText` reads that output one bounded page at a time.
    const text = partTextOf(&sess, 1, 0, "output") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(huge.len, text.len);
}

test "every cut address resolves to its own field, never a neighbour" {
    const gpa = testing.allocator;
    const sid = SessionId.bytes([_]u8{5} ** 16);
    var sess = domain_session.Session.init(gpa, sid);
    defer sess.deinit();

    const input_views = [_]proto.view.View{.{ .markdown = .{ .text = "input view text" } }};
    const state_views = [_]proto.view.View{
        .{ .text = .{ .text = "first view" } },
        .{ .json = .{ .text = "{\"second\":true}" } },
    };
    const content = [_]proto.message.AssistantPart{.{ .tool = .{
        .id = 0,
        .name = "exec",
        .arguments = "{\"command\":\"zig build\"}",
        .input_view = &input_views,
        .state = .{ .completed = .{ .output = "the output", .view = &state_views, .duration_ms = 5 } },
    } }};
    const messages = [_]proto.message.Message{.{ .assistant = .{
        .id = 1,
        .run_id = 1,
        .config_rev = 0,
        .agent = "claude",
        .content = &content,
        .time = .{ .created_at_ms = 1 },
    } }};
    try sess.installSnapshot(.{ .base_seq = 1, .finalized_message_id = 1, .messages = &messages, .has_more = false });

    // Each address answers its own field. Before the address existed, every one of these gave the output.
    try testing.expectEqualStrings("{\"command\":\"zig build\"}", partTextOf(&sess, 1, 0, "arguments").?);
    try testing.expectEqualStrings("the output", partTextOf(&sess, 1, 0, "output").?);
    try testing.expectEqualStrings("input view text", partTextOf(&sess, 1, 0, "input_view.0.text").?);
    try testing.expectEqualStrings("first view", partTextOf(&sess, 1, 0, "view.0.text").?);
    try testing.expectEqualStrings("{\"second\":true}", partTextOf(&sess, 1, 0, "view.1.text").?);

    // An address that names nothing answers null, because `field` arrives from JavaScript.
    try testing.expect(partTextOf(&sess, 1, 0, "error") == null);
    try testing.expect(partTextOf(&sess, 1, 0, "view.9.text") == null);
    try testing.expect(partTextOf(&sess, 1, 0, "view.x.text") == null);
    try testing.expect(partTextOf(&sess, 1, 0, "view.0") == null);
    try testing.expect(partTextOf(&sess, 1, 0, "text") == null);
    try testing.expect(partTextOf(&sess, 1, 0, "") == null);
}

test "a text part over the inline bound reports more and pages back whole" {
    const gpa = testing.allocator;
    const sid = SessionId.bytes([_]u8{4} ** 16);
    var sess = domain_session.Session.init(gpa, sid);
    defer sess.deinit();

    // A multibyte run straddles every plausible page edge, so a lost or split character shows up.
    const long = try gpa.alloc(u8, 3 * 24_000);
    defer gpa.free(long);
    for (0..long.len / 3) |i| @memcpy(long[i * 3 ..][0..3], "\u{2014}");

    const content = [_]proto.message.AssistantPart{.{ .text = .{ .id = 0, .text = long } }};
    const messages = [_]proto.message.Message{.{ .assistant = .{
        .id = 1,
        .run_id = 1,
        .config_rev = 0,
        .agent = "claude",
        .content = &content,
        .time = .{ .created_at_ms = 1 },
    } }};
    try sess.installSnapshot(.{ .base_seq = 1, .finalized_message_id = 1, .messages = &messages, .has_more = false });

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeMessageParts(&aw.writer, &sess, 1);

    // The view learns the text is cut and how large it really is, which is what asks it to page.
    // The cut names the field, the whole size, and where a reader resumes, so the prefix is not re-fetched.
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"cut\":[{\"field\":\"text\",\"bytes\":72000,\"next\":65535}]") != null);

    const whole = partTextOf(&sess, 1, 0, "text") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(long.len, whole.len);

    // The page loop echoes `next`, so it must rebuild the text with no gap and no repeat.
    var rebuilt: std.ArrayList(u8) = .empty;
    defer rebuilt.deinit(gpa);
    var offset: usize = 0;
    while (offset < whole.len) {
        const cut = offset + utf8Floor(whole[offset..], 1000);
        try testing.expect(cut > offset); // a page always advances, so the loop ends
        try rebuilt.appendSlice(gpa, whole[offset..cut]);
        offset = cut;
    }
    try testing.expectEqualStrings(whole, rebuilt.items);
}

test "a throwing event sink faults once and leaves no pending exception" {
    const host = try Host.create(testing.allocator);
    defer host.destroy();

    try host.evalModule(
        \\import { native } from "yuke:engine-native";
        \\globalThis.seen = 0;
        \\native.setEventSink(() => { globalThis.seen++; throw new Error("bad handler"); });
    , "sink.js");

    // Two dirty sessions: the drain must report the fault and still deliver both events.
    host.engine.markDirty(SessionId.bytes([_]u8{1} ** 16), .{ .structural = true });
    host.engine.markDirty(SessionId.bytes([_]u8{2} ** 16), .{ .structural = true });
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
    host.engine.markDirty(SessionId.bytes([_]u8{3} ** 16), .{ .structural = true });
    try testing.expect(!drain(host.engine, host.ctx));
}
