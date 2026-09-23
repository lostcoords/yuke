//! Paged text reads over one session: a part field or a view, one bounded window at a time.

const std = @import("std");
const proto = @import("proto");
const utf8 = @import("../../../utf8.zig");
const domain_session = @import("../../../session/session.zig");
const domain_draft = @import("../../../session/draft.zig");

const SessionId = proto.ids.SessionId;

/// One text read copies at most this many bytes; a part inlines its first page, and a limit of zero asks for this default.
pub const max_page_bytes: usize = 64 * 1024;
/// The widest UTF-8 character, so a page below this size can hold no character.
pub const max_char_bytes: usize = 4;

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

/// One page of one field: the whole characters it holds and where a reader resumes.
const FieldPage = struct { text: []const u8, next: ?usize };

/// Page one field from `offset`, and answer null when no whole character is left.
pub fn fieldPage(text: []const u8, offset: u64, want: usize) ?FieldPage {
    std.debug.assert(want >= max_char_bytes); // pageLimit resolved this, so a whole character always fits
    if (offset >= text.len) return null;
    const from: usize = @intCast(offset);
    const start = from + utf8.head(text[from..]); // an offset inside a character resumes at the next one
    const cut = start + utf8.floor(text[start..], want);
    if (cut == start) return null;
    return .{ .text = text[start..cut], .next = if (cut < text.len) cut else null };
}

/// Find the text of one part, in the draft or the committed window.
pub fn partTextOf(s: *domain_session.Session, mid: u64, part_id: u64, field: []const u8) ?[]const u8 {
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
            // A user part has no wire id, so `part_id` is its position, the same address the projection wrote.
            .user => |u| {
                if (part_id >= u.content.len or !std.mem.eql(u8, field, "text")) return null;
                return switch (u.content[@intCast(part_id)]) {
                    .text => |t| t.text,
                    else => null,
                };
            },
            .compaction => |c| return c.summary,
        }
        return null;
    }
    return null;
}

/// Resolve a page limit. Absent or zero means one default page, and every page holds one whole character.
pub fn pageLimit(raw: ?u64) usize {
    const want = raw orelse 0;
    if (want == 0) return max_page_bytes;
    const capped: usize = @intCast(@min(want, max_page_bytes));
    return @max(capped, max_char_bytes);
}

const testing = std.testing;

/// Seed a test session with committed messages the way hydrate does.
pub fn seedHistory(sess: *domain_session.Session, messages: []const proto.message.Message) !void {
    for (messages) |m| try sess.transcript.append(m);
    sess.sealHistory(1, false);
}

test "a page limit always holds one whole character" {
    try testing.expectEqual(max_page_bytes, pageLimit(null));
    try testing.expectEqual(max_page_bytes, pageLimit(0)); // zero asks for the default page
    try testing.expectEqual(max_page_bytes, pageLimit(max_page_bytes + 1)); // the cap bounds a large ask
    try testing.expectEqual(max_char_bytes, pageLimit(1)); // a one-byte page would never advance
    try testing.expectEqual(@as(usize, 64), pageLimit(64));
}

/// Read `text` page by page through `fieldPage`, as a view does, and answer the text the pages rebuild.
pub fn rebuildFieldPages(gpa: std.mem.Allocator, text: []const u8, want: usize) ![]u8 {
    var rebuilt: std.ArrayList(u8) = .empty;
    errdefer rebuilt.deinit(gpa);
    var offset: u64 = 0;
    while (fieldPage(text, offset, want)) |page| {
        try testing.expect(std.unicode.utf8ValidateSlice(page.text)); // no page ever splits a character
        try rebuilt.appendSlice(gpa, page.text);
        const next = page.next orelse break;
        try testing.expect(next > offset); // a page always advances, so the loop ends
        offset = next;
    }
    return rebuilt.toOwnedSlice(gpa);
}

test "a field pages whole characters and advances on the smallest page" {
    const text = "\u{1F642}a\u{2014}b\u{00E9}";
    const rebuilt = try rebuildFieldPages(testing.allocator, text, pageLimit(1));
    defer testing.allocator.free(rebuilt);
    try testing.expectEqualStrings(text, rebuilt);

    // An offset inside a character resumes at the next one instead of answering orphan bytes.
    const inside = fieldPage(text, 1, pageLimit(0)).?;
    try testing.expect(std.unicode.utf8ValidateSlice(inside.text));
    try testing.expectEqualStrings(text[4..], inside.text);

    // A provider can store a broken character, so the page ends and never faults.
    const broken = "ab\xF0\x9F\x99";
    const head = fieldPage(broken, 0, pageLimit(0)).?;
    try testing.expectEqualStrings("ab", head.text); // the broken character never reaches a reader
    try testing.expectEqual(@as(?usize, 2), head.next);
    try testing.expect(fieldPage(broken, head.next.?, pageLimit(0)) == null); // the next page ends the read
}
