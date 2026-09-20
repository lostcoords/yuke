//! Build a session's prompt at run start. The engine supplies the facts; a `prompt.build` handler supplies the sections.

const std = @import("std");
const builtin = @import("builtin");
const proto = @import("proto");
const Engine = @import("Engine.zig");
const RunSlot = @import("run.zig").RunSlot;
const database = @import("../store/store.zig");
const prompts = @import("../session/prompt.zig");

pub const Section = prompts.Section;

/// One AGENTS.md snapshot as the hook payload carries it.
const Instruction = struct { scope: proto.instructions.InstructionScope, path: []const u8, text: []const u8 };
/// One skill as the hook payload carries it. The body loads through the skill tool.
const Skill = struct { name: []const u8, description: []const u8 };

/// The facts every prompt starts from. The date is the session start, so a rebuild never moves it.
const Context = struct {
    session_id: proto.ids.SessionId,
    parent_id: ?proto.ids.SessionId,
    depth: u32,
    agent_name: []const u8,
    workspace: []const u8,
    operating_system: []const u8,
    shell: []const u8,
    session_start_date_utc: []const u8,
};

const Answer = struct { sections: []const Section };

/// Bring the slot's prompt up to the engine generation. A current prompt asks nothing; a stale one runs the hook and stores the answer.
pub fn refresh(engine: *Engine, arena: std.mem.Allocator, slot: *RunSlot) !void {
    std.debug.assert(slot.phase == .running);
    std.debug.assert(engine.prompt_generation != database.session.stale_generation);
    const db = engine.deps.db;
    const sid = slot.sessionId().raw;
    const stored = (try database.session.prompt(db, arena, sid)) orelse return error.MissingSessionPrompt;
    if (stored.generation == engine.prompt_generation) {
        std.debug.assert(std.mem.eql(u8, stored.text, slot.config.system_prompt));
        return;
    }
    const snapshot = (try database.session.snapshot(db, arena, sid)) orelse return error.UnknownSession;
    const sources = try database.session.instructionSnapshots(db, arena, sid);
    const instructions = try arena.alloc(Instruction, sources.len);
    for (sources, instructions) |source, *out| out.* = .{ .scope = source.source.scope, .path = source.source.path, .text = source.text };
    const catalog = try database.session.skillCatalog(db, arena, sid);
    const skills = try arena.alloc(Skill, catalog.len);
    for (catalog, skills) |entry, *out| out.* = .{ .name = entry.name, .description = entry.description };
    const seed = try database.session.promptSections(db, arena, sid);
    var sections = seed;
    switch (engine.deps.hooks.askIfHeld(arena, .@"prompt.build", .{
        .context = Context{
            .session_id = slot.sessionId(),
            .parent_id = slot.parent_id,
            .depth = slot.depth,
            .agent_name = slot.config.name orelse "root",
            .workspace = slot.config.root,
            .operating_system = @tagName(builtin.os.tag),
            .shell = engine.deps.execution.shell.path,
            .session_start_date_utc = try dateOf(arena, snapshot.created_at_ms),
        },
        .instructions = instructions,
        .skills = skills,
        .sections = seed,
    })) {
        .proceed => {},
        .replace => |value| {
            const answer = std.json.parseFromValueLeaky(Answer, arena, value, .{ .ignore_unknown_fields = true }) catch null;
            if (answer != null and prompts.valid(answer.?.sections)) sections = answer.?.sections else std.log.warn("run {d} prompt.build answered unreadable sections; the run keeps the seed sections", .{slot.runId()});
        },
        .block => |reason| {
            std.log.warn("run {d} stopped at prompt.build: {s}", .{ slot.runId(), reason });
            return error.HookBlocked;
        },
        .canceled => return error.Canceled,
    }
    const text = blk: {
        var tx = try db.begin();
        defer tx.deinit();
        const rendered = try database.session.setPrompt(db, arena, sid, sections, engine.prompt_generation);
        try tx.commit();
        break :blk rendered;
    };
    // The slot owns its prompt for the run, so the fresh text replaces the copy the prepare made.
    const owned = try slot.gpa.dupe(u8, text);
    slot.gpa.free(slot.config.system_prompt);
    slot.config.system_prompt = owned;
}

/// The calendar date of `created_at_ms` in UTC, as `YYYY-MM-DD`.
fn dateOf(arena: std.mem.Allocator, created_at_ms: u64) ![]const u8 {
    std.debug.assert(created_at_ms <= std.math.maxInt(u48));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = created_at_ms / 1000 };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year_day.year, month_day.month.numeric(), @as(u8, month_day.day_index) + 1 });
}

test "the session start date renders as a UTC calendar day" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("1970-01-01", try dateOf(arena.allocator(), 0));
    try std.testing.expectEqualStrings("2026-09-19", try dateOf(arena.allocator(), 1789847686816));
}
