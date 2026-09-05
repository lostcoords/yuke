//! The parts projection: a message as JSON with every string bounded, and the outline the view reads.

const std = @import("std");
const proto = @import("proto");
const utf8 = @import("../../../utf8.zig");
const domain_session = @import("../../../session/session.zig");
const domain_draft = @import("../../../session/draft.zig");

const SessionId = proto.ids.SessionId;
const paging = @import("paging.zig");

const max_page_bytes = paging.max_page_bytes;

pub fn messageError(m: proto.message.Message) ?proto.message.MessageError {
    return switch (m) {
        .assistant => |a| a.@"error",
        else => null,
    };
}

/// Write the message ids and roles of one session. The list is small, so it is not paged.
pub fn writeOutline(w: *std.Io.Writer, s: *domain_session.Session) !void {
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
/// What one diff file or hunk costs in keys and brackets. The budget charges it, so structure cannot escape the bound.
const diff_scaffold_bytes: usize = 128;

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

/// One part may inline this many bytes across its strings, whichever call asks for it. The rest is paged.
pub const max_part_bytes: usize = 4 * max_page_bytes;

/// What a part carries as it writes: its cuts, and the bytes it may still inline.
const Parts = struct {
    cuts: Cuts = .{},
    left: usize = max_part_bytes,

    /// Spend up to `want` bytes of the budget and answer what it allowed.
    fn take(self: *Parts, want: usize) usize {
        const n = @min(want, self.left);
        self.left -= n;
        return n;
    }
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
fn writeCapped(w: *std.Io.Writer, parts: *Parts, field: Cut.Field, list: []const u8, index: u32, name: []const u8, text: []const u8) !void {
    const end = utf8.floor(text, parts.take(@min(text.len, max_page_bytes)));
    try w.print("\"{s}\":", .{name});
    try std.json.Stringify.encodeJsonString(text[0..end], .{}, w);
    if (end < text.len) parts.cuts.add(.{ .field = field, .list = list, .index = index, .size = text.len, .next = end });
}

/// Write one part. Every string it holds is bounded, whatever the tool produced.
fn writePart(w: *std.Io.Writer, parts: *Parts, p: proto.message.AssistantPart) !void {
    parts.* = .{};
    switch (p) {
        .text => |t| try writeTextPart(w, parts, "text", t.id, t.text),
        .reasoning => |r| try writeTextPart(w, parts, "reasoning", r.id, r.text),
        .redacted_reasoning => |r| try w.print("{{\"type\":\"redacted_reasoning\",\"id\":{d}}}", .{r.id}),
        .tool => |t| try writeToolPart(w, parts, t),
    }
}

/// Write a text-bearing part. A cut text names itself in `cut`, so a view knows to page the rest.
fn writeTextPart(w: *std.Io.Writer, parts: *Parts, kind: []const u8, id: u64, text: []const u8) !void {
    const end = utf8.floor(text, parts.take(@min(text.len, max_page_bytes)));
    try w.print("{{\"type\":\"{s}\",\"id\":{d},\"text\":", .{ kind, id });
    try std.json.Stringify.encodeJsonString(text[0..end], .{}, w);
    if (end < text.len) parts.cuts.add(.{ .field = .text, .size = text.len, .next = end });
    try parts.cuts.write(w);
    try w.writeByte('}');
}

/// Write a tool part field by field. A generic encode here would copy a whole tool result.
fn writeToolPart(w: *std.Io.Writer, parts: *Parts, t: proto.message.ToolPart) !void {
    try w.print("{{\"type\":\"tool\",\"id\":{d},\"name\":", .{t.id});
    try std.json.Stringify.encodeJsonString(t.name, .{}, w);
    if (t.call_id) |call_id| {
        try w.writeAll(",\"call_id\":");
        try std.json.Stringify.encodeJsonString(call_id, .{}, w);
    }
    try w.writeByte(',');
    try writeCapped(w, parts, .arguments, "", 0, "arguments", t.arguments);
    if (t.input_view) |views| {
        try w.writeAll(",\"input_view\":");
        try writeViews(w, parts, "input_view", views);
    }
    try w.writeAll(",\"state\":");
    try writeToolState(w, parts, t.state);
    try parts.cuts.write(w);
    try w.writeByte('}');
}

fn writeToolState(w: *std.Io.Writer, parts: *Parts, state: proto.tool.ToolState) !void {
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
                try writeCapped(w, parts, .output, "", 0, "output", out);
            }
            try w.writeByte('}');
        },
        .completed => |c| {
            try w.print("{{\"type\":\"completed\",\"duration_ms\":{d},", .{c.duration_ms});
            try writeCapped(w, parts, .output, "", 0, "output", c.output);
            if (c.view) |views| {
                try w.writeAll(",\"view\":");
                try writeViews(w, parts, "view", views);
            }
            try w.writeByte('}');
        },
        .@"error" => |e| {
            try w.print("{{\"type\":\"error\",\"duration_ms\":{d},", .{e.duration_ms});
            try writeCapped(w, parts, .@"error", "", 0, "error", e.@"error");
            if (e.view) |views| {
                try w.writeAll(",\"view\":");
                try writeViews(w, parts, "view", views);
            }
            try w.writeByte('}');
        },
    }
}

/// Write at most `max_inline_views` views. A dropped view is recorded, so a row can say how many it hides.
fn writeViews(w: *std.Io.Writer, parts: *Parts, list: []const u8, views: []const proto.view.View) !void {
    try w.writeByte('[');
    const shown = @min(views.len, max_inline_views);
    for (views[0..shown], 0..) |v, i| {
        if (i > 0) try w.writeByte(',');
        try writeView(w, parts, list, @intCast(i), v);
    }
    try w.writeByte(']');
    if (shown < views.len) parts.cuts.add(.{ .field = .view_count, .list = list, .size = views.len });
}

fn writeView(w: *std.Io.Writer, parts: *Parts, list: []const u8, index: u32, v: proto.view.View) !void {
    switch (v) {
        .text => |t| {
            try w.writeAll("{\"type\":\"text\",");
            try writeCapped(w, parts, .view_text, list, index, "text", t.text);
            if (t.language) |lang| {
                try w.writeAll(",\"language\":");
                try std.json.Stringify.encodeJsonString(lang, .{}, w);
            }
            try w.writeByte('}');
        },
        .markdown => |t| {
            try w.writeAll("{\"type\":\"markdown\",");
            try writeCapped(w, parts, .view_text, list, index, "text", t.text);
            try w.writeByte('}');
        },
        .json => |t| {
            try w.writeAll("{\"type\":\"json\",");
            try writeCapped(w, parts, .view_text, list, index, "text", t.text);
            try w.writeByte('}');
        },
        // An image view names a blob; it carries no inline bytes.
        .image => |t| try std.json.Stringify.value(v: {
            break :v .{ .type = "image", .source = t.source, .alt = t.alt };
        }, .{ .emit_null_optional_fields = false }, w),
        .diff => |d| try writeDiff(w, parts, list, index, d),
    }
}

/// Write a diff with a bounded line count. A transcript shows a preview, never a whole patch.
fn writeDiff(w: *std.Io.Writer, parts: *Parts, list: []const u8, index: u32, d: proto.view.ViewDiff) !void {
    // Count first, because the walk stops early and the reader still wants the whole size.
    var total: u64 = 0;
    for (d.files) |file| for (file.hunks) |hunk| {
        total += hunk.lines.len;
    };

    var budget: usize = max_inline_diff_lines;
    var shortened: u64 = 0;
    var written: usize = 0;
    try w.writeAll("{\"type\":\"diff\",\"files\":[");
    for (d.files) |file| {
        // Charge the keys and brackets before writing them, so a file the budget cannot afford ends the walk.
        if (parts.take(diff_scaffold_bytes) < diff_scaffold_bytes) break;
        if (written > 0) try w.writeByte(',');
        written += 1;
        try w.writeAll("{\"path\":");
        _ = try writeFloor(w, parts, file.path);
        if (file.old_path) |old| {
            try w.writeAll(",\"old_path\":");
            _ = try writeFloor(w, parts, old);
        }
        try w.writeAll(",\"hunks\":[");
        var hunks: usize = 0;
        for (file.hunks) |hunk| {
            if (parts.take(diff_scaffold_bytes) < diff_scaffold_bytes) break;
            if (hunks > 0) try w.writeByte(',');
            hunks += 1;
            try w.print("{{\"old_start\":{d},\"old_lines\":{d},\"new_start\":{d},\"new_lines\":{d},\"lines\":[", .{
                hunk.old_start, hunk.old_lines, hunk.new_start, hunk.new_lines,
            });
            const shown = @min(hunk.lines.len, budget);
            for (hunk.lines[0..shown], 0..) |line, li| {
                if (li > 0) try w.writeByte(',');
                if (try writeFloor(w, parts, line)) shortened += 1;
            }
            budget -= shown;
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
    // A dropped file, a dropped line and a shortened line all abbreviate the diff, and the reader gets the whole count.
    if (written < d.files.len or total > max_inline_diff_lines or shortened > 0) {
        parts.cuts.add(.{ .field = .view_diff, .list = list, .index = index, .size = total });
    }
}

/// Write one diff string cut to the budget and the line cap. Answer whether the cap shortened it.
fn writeFloor(w: *std.Io.Writer, parts: *Parts, text: []const u8) !bool {
    const end = utf8.floor(text, parts.take(@min(text.len, max_inline_line_bytes)));
    try std.json.Stringify.encodeJsonString(text[0..end], .{}, w);
    return end < text.len;
}

/// Write the parts of one message as a JSON array. With `only`, write just that part, so a delta reads one part.
pub fn writeMessageParts(w: *std.Io.Writer, s: *domain_session.Session, mid: proto.ids.MessageId, only: ?proto.ids.PartId) !void {
    var parts: Parts = .{};
    var written: usize = 0;
    try w.writeByte('[');
    if (s.draft) |*d| if (d.message_id == mid) {
        for (d.parts.items) |*p| {
            const wire = domain_draft.partToWire(p);
            if (only) |want| if (wire.id() != want) continue;
            if (written > 0) try w.writeByte(',');
            written += 1;
            try writePart(w, &parts, wire);
        }
        return w.writeByte(']');
    };
    for (s.transcript.list.items) |entry| {
        if (entry.message.id() != mid) continue;
        switch (entry.message) {
            .assistant => |a| for (a.content) |p| {
                if (only) |want| if (p.id() != want) continue;
                if (written > 0) try w.writeByte(',');
                written += 1;
                try writePart(w, &parts, p);
            },
            else => {},
        }
        return w.writeByte(']');
    }
    try w.writeByte(']');
}

const testing = std.testing;
const seedHistory = paging.seedHistory;
const partTextOf = paging.partTextOf;
const pageLimit = paging.pageLimit;

/// The `cut` entry of one part for `field`, read from the JSON the writer produced, so a test pins no key order.
fn cutOf(arena: std.mem.Allocator, json: []const u8, part: usize, field: []const u8) !?std.json.ObjectMap {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    const cuts = parsed.array.items[part].object.get("cut") orelse return null;
    for (cuts.array.items) |cut| {
        if (std.mem.eql(u8, cut.object.get("field").?.string, field)) return cut.object;
    }
    return null;
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
    try seedHistory(&sess, &messages);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeMessageParts(&aw.writer, &sess, 1, null);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    // Three megabytes of source must not become a three-megabyte projection. One page per string bounds it.
    try testing.expect(aw.written().len < 4 * max_page_bytes);
    // The response still says how large the output really is, so a view can page it.
    const output = (try cutOf(arena.allocator(), aw.written(), 0, "output")).?;
    try testing.expectEqual(@as(i64, @intCast(huge.len)), output.get("bytes").?.integer);
    try testing.expectEqual(@as(i64, max_page_bytes), output.get("next").?.integer);
    // The one diff line is far over the line cap, and the response says so instead of eliding in silence.
    try testing.expectEqual(@as(i64, 1), (try cutOf(arena.allocator(), aw.written(), 0, "view.0.diff")).?.get("total").?.integer);

    // `partText` reads that output one bounded page at a time.
    const text = partTextOf(&sess, 1, 0, "output") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(huge.len, text.len);
}

test "a diff of many files stays inside the response budget" {
    const gpa = testing.allocator;
    const sid = SessionId.bytes([_]u8{7} ** 16);
    var sess = domain_session.Session.init(gpa, sid);
    defer sess.deinit();

    // A path and its scaffolding cost bytes even when no line is written, so the file count must not escape the budget.
    const path = "a" ** 200;
    const lines = [_][]const u8{"x"};
    const hunks = [_]proto.view.DiffHunk{.{ .old_start = 1, .old_lines = 1, .new_start = 1, .new_lines = 1, .lines = &lines }};
    const files = try gpa.alloc(proto.view.DiffFile, 10_000);
    defer gpa.free(files);
    for (files) |*f| f.* = .{ .path = path, .hunks = &hunks };
    const views = [_]proto.view.View{.{ .diff = .{ .files = files } }};
    const content = [_]proto.message.AssistantPart{.{ .tool = .{
        .id = 0,
        .name = "exec",
        .arguments = "{}",
        .state = .{ .completed = .{ .output = "", .view = &views, .duration_ms = 1 } },
    } }};
    const messages = [_]proto.message.Message{.{ .assistant = .{
        .id = 1,
        .run_id = 1,
        .config_rev = 0,
        .agent = "claude",
        .content = &content,
        .time = .{ .created_at_ms = 1 },
    } }};
    try seedHistory(&sess, &messages);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeMessageParts(&aw.writer, &sess, 1, null);

    try testing.expect(aw.written().len < 2 * max_part_bytes);
    // The diff says how many lines the whole patch holds, so a row can mark what it hides.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try testing.expectEqual(@as(i64, 10_000), (try cutOf(arena.allocator(), aw.written(), 0, "view.0.diff")).?.get("total").?.integer);
}

test "many huge parts each stay inside the part budget and none is dropped" {
    const gpa = testing.allocator;
    const sid = SessionId.bytes([_]u8{6} ** 16);
    var sess = domain_session.Session.init(gpa, sid);
    defer sess.deinit();

    const huge = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(huge);
    @memset(huge, 'x');

    // The per-field cap alone never bounded a message; only the count of parts did.
    const part_count = 64;
    const content = try gpa.alloc(proto.message.AssistantPart, part_count);
    defer gpa.free(content);
    for (content, 0..) |*part, i| {
        part.* = .{ .tool = .{
            .id = i,
            .name = "exec",
            .arguments = huge,
            .state = .{ .completed = .{ .output = huge, .duration_ms = 5 } },
        } };
    }
    const messages = [_]proto.message.Message{.{ .assistant = .{
        .id = 1,
        .run_id = 1,
        .config_rev = 0,
        .agent = "claude",
        .content = content,
        .time = .{ .created_at_ms = 1 },
    } }};
    try seedHistory(&sess, &messages);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeMessageParts(&aw.writer, &sess, 1, null);

    // 128 megabytes of source project into the budget and its own structure, never into a copy.
    try testing.expect(aw.written().len < (part_count + 1) * max_part_bytes);

    // The budget shortens a first page; it never drops a part, because `partText` still reaches the rest.
    try testing.expectEqual(part_count, std.mem.count(u8, aw.written(), "\"type\":\"tool\""));
    const last = partTextOf(&sess, 1, part_count - 1, "output") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(huge.len, last.len);
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
    try seedHistory(&sess, &messages);

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
    try seedHistory(&sess, &messages);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeMessageParts(&aw.writer, &sess, 1, null);

    // The cut names the field, the whole size, and where a reader resumes on a character boundary.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const cut = (try cutOf(arena.allocator(), aw.written(), 0, "text")).?;
    try testing.expectEqual(@as(i64, @intCast(long.len)), cut.get("bytes").?.integer);
    try testing.expectEqual(@as(i64, @intCast(utf8.floor(long, max_page_bytes))), cut.get("next").?.integer);

    const whole = partTextOf(&sess, 1, 0, "text") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(long.len, whole.len);

    // The page loop echoes `next`, so it must rebuild the text with no gap and no repeat.
    const rebuilt = try paging.rebuildFieldPages(gpa, whole, pageLimit(1000));
    defer gpa.free(rebuilt);
    try testing.expectEqualStrings(whole, rebuilt);
}
