//! Commit components use the production draft, store, and transcript paths.

const std = @import("std");
const proto = @import("proto");
const store = @import("../store/store.zig");
const Draft = @import("../session/draft.zig").Draft;
const transcript = @import("../session/transcript.zig");
const Commit = @This();

pub const Mode = enum { commit, commit_serialize, commit_size };
const sid = proto.ids.SessionId.bytes([_]u8{7} ** 16);

gpa: std.mem.Allocator,
db: store.Database,
draft: Draft,
resident: transcript.Transcript,
source_bytes: usize,
expected_bytes: usize,
steps: u64 = 0,

pub fn create(gpa: std.mem.Allocator, scale: u32) !*Commit {
    std.debug.assert(scale > 0);
    const self = try gpa.create(Commit);
    errdefer gpa.destroy(self);
    var db = try store.Database.openTest();
    errdefer db.deinit();
    try store.session.create(&db, .{ .id = sid.raw, .root = "/bench", .origin = "root", .profile = "default", .model = "bench", .reasoning = "high", .config_rev = 0, .title = "bench", .created_at_ms = 1, .updated_at_ms = 1 });
    var draft = try Draft.init(gpa, .{ .session_id = sid, .message_id = 100000, .run_id = 1, .config_rev = 0, .agent = "bench", .created_at_ms = 1 });
    errdefer draft.deinit();
    const unit = "Text 世界 \"quoted\" \\ path\n";
    const body = try gpa.alloc(u8, unit.len * 128 * scale);
    defer gpa.free(body);
    var at: usize = 0;
    while (at < body.len) : (at += unit.len) @memcpy(body[at..][0..unit.len], unit);
    try draft.addPart(.{ .session_id = sid, .message_id = 100000, .part = .{ .text = .{ .id = 0, .text = body } } });
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var m = (try draft.toActiveDraft(arena.allocator())).message;
    m.finish = .stop;
    self.* = .{ .gpa = gpa, .db = db, .draft = draft, .resident = .init(gpa), .source_bytes = body.len, .expected_bytes = try transcript.messageBytes(.{ .assistant = m }) };
    self.resident.max_messages = 1;
    return self;
}

pub fn destroy(self: *Commit) void {
    const gpa = self.gpa;
    self.resident.deinit();
    self.draft.deinit();
    self.db.deinit();
    gpa.destroy(self);
}

pub fn step(self: *Commit, mode: Mode) !void {
    std.debug.assert(self.expected_bytes > self.source_bytes);
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var m = (try self.draft.toActiveDraft(a)).message;
    m.finish = .stop;
    if (self.steps >= 900000) return error.TooManyCommitSamples;
    m.id += self.steps;
    const message: proto.message.Message = .{ .assistant = m };
    switch (mode) {
        .commit_size => if (try transcript.messageBytes(message) != self.expected_bytes) return error.SizeMismatch,
        .commit_serialize => {
            const bytes = try std.json.Stringify.valueAlloc(a, message, .{ .emit_null_optional_fields = false });
            if (bytes.len != self.expected_bytes) return error.SizeMismatch;
        },
        .commit => {
            const owned = try proto.dupe(a, message);
            var tx = try self.db.begin();
            defer tx.deinit();
            const commit = try store.message.appendCommittedMessage(&self.db, a, sid.raw, std.mem.toBytes(@as(u128, m.id)), 1, owned);
            if (commit.data.seq != self.steps + 1) return error.SequenceMismatch;
            try tx.commit();
            try self.resident.appendSized(commit.data.message, commit.bytes);
        },
    }
    self.steps += 1;
}

pub fn verify(self: *Commit, mode: Mode) !i32 {
    std.debug.assert(self.steps > 0);
    if (mode == .commit) {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const snapshot = (try store.session.snapshot(&self.db, a, sid.raw)).?;
        if (snapshot.message_count != self.steps) return error.CountMismatch;
        const history = try store.message.historyPage(&self.db, a, sid.raw, 0, 1);
        if (history.messages.len != 1 or history.messages[0].id() != 100000 + self.steps - 1) return error.StoredMessageMismatch;
        const resident = try self.resident.sized(a);
        if (resident.len != 1 or resident[0].bytes != self.expected_bytes) return error.TranscriptMismatch;
        if (!std.mem.eql(u8, history.messages[0].assistant.content[0].text.text, resident[0].message.assistant.content[0].text.text)) return error.StoredContentMismatch;
        if (!std.mem.eql(u8, resident[0].message.assistant.content[0].text.text, self.draft.parts.items[0].text.text.items)) return error.ContentMismatch;
    }
    return @intCast(self.expected_bytes);
}
