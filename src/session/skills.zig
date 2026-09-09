//! Load the two skill roots into a catalog of names and descriptions, and read one body at invocation.

const std = @import("std");
const proto = @import("proto");
const paths = @import("../paths.zig");

pub const Entry = proto.skill.SkillInfo;
pub const max_file_bytes = 256 * 1024;
/// The scan reads only this much of a file, so the frontmatter must end inside it.
pub const max_frontmatter_bytes = 16 * 1024;
/// A root with more candidates than this is a wrong directory, not a skill problem.
pub const max_per_root = 256;
/// A root with more direct entries than this is a wrong directory, so the scan stops before it sorts them.
pub const max_root_entries = 1024;
pub const max_name_bytes = 64;
pub const max_description_chars = 1024;

/// This is one skill the scan left out. The caller reports it as a notice.
pub const Skipped = struct {
    path: []const u8,
    reason: []const u8,
};

pub const Catalog = struct {
    /// The entries are sorted by name. A workspace entry hides a global entry with the same name.
    entries: []const Entry,
    skipped: []const Skipped,
};

/// The body of one skill and the directory that anchors its relative paths.
pub const Body = struct {
    body: []const u8,
    directory: []const u8,
};

pub const LoadError = error{ OutOfMemory, Canceled, TooManySkills };

/// Scan `<workspace>/.agents/skills` then `~/.agents/skills`. Each direct subdirectory with a SKILL.md is a candidate.
pub fn load(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, workspace: []const u8) LoadError!Catalog {
    std.debug.assert(std.fs.path.isAbsolute(workspace));
    const home = paths.homeDir(env);
    const global = if (home != null and std.fs.path.isAbsolute(home.?)) try std.fs.path.join(arena, &.{ home.?, ".agents", "skills" }) else null;
    const local = try std.fs.path.join(arena, &.{ workspace, ".agents", "skills" });
    var entries: std.ArrayList(Entry) = .empty;
    var skipped: std.ArrayList(Skipped) = .empty;
    // The workspace root scans first, so its names and canonical paths win.
    for ([_]?[]const u8{ local, global }, [_]proto.instructions.InstructionScope{ .workspace, .global }) |candidate, scope| {
        const root = candidate orelse continue;
        try scanRoot(arena, io, root, scope, &entries, &skipped);
    }
    std.mem.sort(Entry, entries.items, {}, lessByName);
    return .{ .entries = entries.items, .skipped = skipped.items };
}

fn lessByName(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn scanRoot(arena: std.mem.Allocator, io: std.Io, root: []const u8, scope: proto.instructions.InstructionScope, entries: *std.ArrayList(Entry), skipped: *std.ArrayList(Skipped)) LoadError!void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.FileNotFound, error.NotDir => return,
        else => {
            try skipped.append(arena, .{ .path = root, .reason = @errorName(err) });
            return;
        },
    };
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var seen: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            try skipped.append(arena, .{ .path = root, .reason = @errorName(err) });
            return;
        },
    }) |item| {
        if (std.mem.eql(u8, item.name, ".") or std.mem.eql(u8, item.name, "..")) continue;
        seen += 1;
        if (seen > max_root_entries) return error.TooManySkills;
        // A wire path is a JSON string, so a name outside UTF-8 cannot name a skill or a notice path.
        if (!std.unicode.utf8ValidateSlice(item.name)) {
            try skipped.append(arena, .{ .path = root, .reason = "a directory name is not valid UTF-8" });
            continue;
        }
        try names.append(arena, try arena.dupe(u8, item.name));
    }
    // Directory order is not stable, so the sorted name order decides the first entry.
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    var candidates: usize = 0;
    for (names.items) |name| {
        const path = try std.fs.path.join(arena, &.{ root, name, "SKILL.md" });
        const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(io, path, arena) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            error.OutOfMemory, error.Canceled => |e| return e,
            else => {
                // A SKILL.md the scan cannot reach still counts toward the bound.
                try countCandidate(&candidates);
                try skipped.append(arena, .{ .path = path, .reason = @errorName(err) });
                continue;
            },
        };
        try countCandidate(&candidates);
        if (!std.unicode.utf8ValidateSlice(canonical)) {
            try skipped.append(arena, .{ .path = path, .reason = "the source path is not valid UTF-8" });
            continue;
        }
        if (holdsCanonical(entries.items, canonical)) continue;
        // The scan keeps only the head of each file, so a root of large skills stays cheap.
        const text = readText(arena, io, canonical, max_frontmatter_bytes) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => |e| return e,
            else => {
                try skipped.append(arena, .{ .path = path, .reason = reasonOf(err) });
                continue;
            },
        };
        const parsed = (try parseFrontmatter(arena, text)) orelse {
            try skipped.append(arena, .{ .path = path, .reason = "the file has no frontmatter" });
            continue;
        };
        const skill_name = parsed.name orelse name;
        if (nameFault(skill_name)) |reason| {
            try skipped.append(arena, .{ .path = path, .reason = reason });
            continue;
        }
        const description = parsed.description orelse "";
        if (descriptionFault(description)) |reason| {
            try skipped.append(arena, .{ .path = path, .reason = reason });
            continue;
        }
        if (holdsName(entries.items, skill_name)) {
            try skipped.append(arena, .{ .path = path, .reason = "another skill already holds this name" });
            continue;
        }
        try entries.append(arena, .{ .name = skill_name, .description = description, .scope = scope, .path = path, .canonical_path = canonical });
    }
}

fn countCandidate(candidates: *usize) error{TooManySkills}!void {
    candidates.* += 1;
    if (candidates.* > max_per_root) return error.TooManySkills;
}

fn holdsCanonical(entries: []const Entry, canonical: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.canonical_path, canonical)) return true;
    return false;
}

fn holdsName(entries: []const Entry, name: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.name, name)) return true;
    return false;
}

pub fn find(entries: []const Entry, name: []const u8) ?Entry {
    for (entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;
    return null;
}

const ReadError = error{ OutOfMemory, Canceled, NotRegularFile, TooLarge, NotUtf8, Unreadable };

/// Read up to `limit` bytes of one SKILL.md. The file itself has the same size bound as an AGENTS.md source.
fn readText(arena: std.mem.Allocator, io: std.Io, canonical: []const u8, limit: usize) ReadError![]const u8 {
    std.debug.assert(limit <= max_file_bytes);
    const stat = std.Io.Dir.cwd().statFile(io, canonical, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unreadable,
    };
    if (stat.kind != .file) return error.NotRegularFile;
    if (stat.size > max_file_bytes) return error.TooLarge;
    if (limit == max_file_bytes) {
        // The whole-file read validates every byte, because the body reaches the model as text.
        const text = std.Io.Dir.cwd().readFileAlloc(io, canonical, arena, .limited(max_file_bytes + 1)) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => |e| return e,
            error.StreamTooLong => return error.TooLarge,
            else => return error.Unreadable,
        };
        if (!std.unicode.utf8ValidateSlice(text)) return error.NotUtf8;
        return text;
    }
    // A head read can stop inside a code point, so the scan validates only the fields it keeps.
    const file = std.Io.Dir.cwd().openFile(io, canonical, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unreadable,
    };
    defer file.close(io);
    const buffer = try arena.alloc(u8, @min(limit, @as(usize, @intCast(stat.size))));
    const n = file.readPositionalAll(io, buffer, 0) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unreadable,
    };
    return buffer[0..n];
}

fn reasonOf(err: ReadError) []const u8 {
    return switch (err) {
        error.NotRegularFile => "the source is not a regular file",
        error.TooLarge => "the file exceeds 256 KiB",
        error.NotUtf8 => "the file is not valid UTF-8",
        error.Unreadable => "the file cannot be read",
        error.OutOfMemory, error.Canceled => unreachable, // The caller returns these before it asks for a reason.
    };
}

/// Return why `name` is not a skill name, or null when it is one.
pub fn nameFault(name: []const u8) ?[]const u8 {
    if (name.len == 0) return "the name is empty";
    if (name.len > max_name_bytes) return "the name exceeds 64 characters";
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return "the name may only hold lowercase letters, digits, and hyphens";
    }
    if (name[0] == '-' or name[name.len - 1] == '-') return "the name must not start or end with a hyphen";
    if (std.mem.indexOf(u8, name, "--") != null) return "the name must not hold consecutive hyphens";
    return null;
}

fn descriptionFault(description: []const u8) ?[]const u8 {
    if (std.mem.trim(u8, description, " \t").len == 0) return "the description is missing";
    const chars = std.unicode.utf8CountCodepoints(description) catch return "the description is not valid UTF-8";
    if (chars > max_description_chars) return "the description exceeds 1024 characters";
    // The XML component admits tab, LF, and CR; every other control character breaks it.
    for (description) |c| if (c < 0x20 and c != '\t' and c != '\n' and c != '\r') return "the description holds a control character";
    return null;
}

/// The two frontmatter fields the catalog uses and the text after the closing delimiter.
pub const Frontmatter = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    body: []const u8,
};

/// Parse the YAML subset skills use: top-level `key: value` with plain, quoted, or block scalars.
pub fn parseFrontmatter(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?Frontmatter {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return null;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, first, " \t\r"), "---")) return null;
    var result: Frontmatter = .{ .body = "" };
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, " \t"), "---")) {
            result.body = std.mem.trim(u8, lines.rest(), " \t\r\n");
            return result;
        }
        // An indented line belongs to a block scalar or a nested mapping, so it is not a catalog field.
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t' or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const raw_value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const value = if (blockStyle(raw_value)) |style| try blockScalar(arena, lines.rest(), style) else try scalar(arena, raw_value);
        // A catalog field is one value, so a trailing line break from a block scalar carries nothing.
        const trimmed = std.mem.trimEnd(u8, value, " \t\r\n");
        if (std.mem.eql(u8, key, "name")) result.name = trimmed;
        if (std.mem.eql(u8, key, "description")) result.description = trimmed;
    }
    return null;
}

const BlockStyle = struct {
    folded: bool,
    chomp: enum { clip, strip, keep },
};

/// Recognize `|`, `>`, and their `-` or `+` chomping forms. Anything else is a plain scalar.
fn blockStyle(value: []const u8) ?BlockStyle {
    if (value.len == 0 or (value[0] != '|' and value[0] != '>')) return null;
    if (value.len > 2) return null;
    const chomp: @FieldType(BlockStyle, "chomp") = if (value.len == 1) .clip else switch (value[1]) {
        '-' => .strip,
        '+' => .keep,
        else => return null,
    };
    return .{ .folded = value[0] == '>', .chomp = chomp };
}

/// Decode the indented lines after a block indicator with YAML folding, indentation, and chomping.
fn blockScalar(arena: std.mem.Allocator, rest: []const u8, style: BlockStyle) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var indent: ?usize = null;
    var pending_breaks: usize = 0;
    var previous_more_indented = false;
    var first = true;
    var final_break = false;
    var probe = std.mem.splitScalar(u8, rest, '\n');
    while (probe.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const stripped = std.mem.trimStart(u8, line, " ");
        if (std.mem.trim(u8, stripped, " \t").len == 0) {
            // The piece after a final line break is not a line, so it adds no break.
            if (probe.index != null) pending_breaks += 1;
            continue;
        }
        // YAML indents with spaces only, so a tab or a shallower line ends the block.
        const width = indent orelse line.len - stripped.len;
        if (width == 0 or line.len - stripped.len < width) break;
        indent = width;
        const content = line[width..];
        const more_indented = content[0] == ' ';
        if (!first) {
            // A fold turns one line break into a space and each blank line into one break.
            const fold = style.folded and !more_indented and !previous_more_indented;
            if (fold and pending_breaks == 0) try out.append(arena, ' ') else try out.appendNTimes(arena, '\n', if (fold) pending_breaks else pending_breaks + 1);
        }
        try out.appendSlice(arena, content);
        first = false;
        final_break = probe.index != null;
        pending_breaks = 0;
        previous_more_indented = more_indented;
    }
    // Chomping keeps the final line break only when the source has one.
    switch (style.chomp) {
        .strip => {},
        .clip => if (final_break) try out.append(arena, '\n'),
        .keep => if (final_break) try out.appendNTimes(arena, '\n', pending_breaks + 1),
    }
    return out.toOwnedSlice(arena);
}

/// Decode one flow scalar: a double-quoted string with escapes, a single-quoted string, or plain text.
fn scalar(arena: std.mem.Allocator, value: []const u8) error{OutOfMemory}![]const u8 {
    if (value.len == 0) return value;
    if (value[0] == '"') return try doubleQuoted(arena, value) orelse value;
    if (value[0] == '\'') return try singleQuoted(arena, value) orelse value;
    // A plain scalar ends at a comment, which YAML marks with a space before the hash.
    const comment = std.mem.indexOf(u8, value, " #");
    return std.mem.trimEnd(u8, if (comment) |at| value[0..at] else value, " \t");
}

/// Null means the quote never closes, so the caller keeps the raw text.
fn doubleQuoted(arena: std.mem.Allocator, value: []const u8) error{OutOfMemory}!?[]const u8 {
    std.debug.assert(value[0] == '"');
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (c == '"') return try out.toOwnedSlice(arena);
        if (c != '\\') {
            try out.append(arena, c);
            continue;
        }
        // A backslash at the end has no escape, so the scalar is malformed.
        if (i + 1 == value.len) return null;
        i += 1;
        const digits: usize = switch (value[i]) {
            'x' => 2,
            'u' => 4,
            'U' => 8,
            else => 0,
        };
        if (digits == 0) {
            try out.append(arena, switch (value[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '0' => 0,
                'a' => 0x07,
                'b' => 0x08,
                'e' => 0x1b,
                'f' => 0x0c,
                'v' => 0x0b,
                else => |escaped| escaped,
            });
            continue;
        }
        if (i + digits >= value.len) return null;
        const code = std.fmt.parseInt(u21, value[i + 1 .. i + 1 + digits], 16) catch return null;
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(code, &buffer) catch return null;
        try out.appendSlice(arena, buffer[0..len]);
        i += digits;
    }
    return null;
}

/// Null means the quote never closes, so the caller keeps the raw text.
fn singleQuoted(arena: std.mem.Allocator, value: []const u8) error{OutOfMemory}!?[]const u8 {
    std.debug.assert(value[0] == '\'');
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i < value.len) : (i += 1) {
        if (value[i] != '\'') {
            try out.append(arena, value[i]);
            continue;
        }
        // Two quotes inside a single-quoted scalar are one literal quote.
        if (i + 1 < value.len and value[i + 1] == '\'') {
            try out.append(arena, '\'');
            i += 1;
            continue;
        }
        return try out.toOwnedSlice(arena);
    }
    return null;
}

/// Read the body of one catalog entry without its frontmatter. The body keeps its own text.
pub fn readBody(arena: std.mem.Allocator, io: std.Io, entry: Entry, diagnostic: ?*?[]const u8) error{ OutOfMemory, Canceled, SkillUnreadable }!Body {
    std.debug.assert(nameFault(entry.name) == null);
    const text = readText(arena, io, entry.canonical_path, max_file_bytes) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => |e| return e,
        else => return refuse(arena, diagnostic, entry.path, reasonOf(err)),
    };
    const parsed = (try parseFrontmatter(arena, text)) orelse return refuse(arena, diagnostic, entry.path, "the file has no frontmatter");
    return .{ .body = parsed.body, .directory = std.fs.path.dirname(entry.canonical_path) orelse entry.canonical_path };
}

fn refuse(arena: std.mem.Allocator, diagnostic: ?*?[]const u8, path: []const u8, reason: []const u8) error{ OutOfMemory, SkillUnreadable } {
    if (diagnostic) |out| out.* = std.fmt.allocPrint(arena, "The engine cannot load the skill at {s}: {s}", .{ path, reason }) catch return error.OutOfMemory;
    return error.SkillUnreadable;
}

/// Wrap one body the way the model and the transcript see it. The body stays literal, as instructions must.
pub fn wrap(arena: std.mem.Allocator, name: []const u8, body: Body) ![]const u8 {
    std.debug.assert(nameFault(name) == null);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "<skill_content name=\"");
    try out.appendSlice(arena, name);
    try out.appendSlice(arena, "\">\n");
    try out.appendSlice(arena, body.body);
    try out.appendSlice(arena, "\n\nSkill directory: ");
    try appendEscaped(arena, &out, body.directory);
    try out.appendSlice(arena, "\nResolve relative paths against this directory.\n</skill_content>");
    return out.toOwnedSlice(arena);
}

const catalog_lead = "Available skills provide specialized instructions for specific tasks. Use the skill tool when a task matches a skill description. Pass the skill name to load its full instructions.\n\n<available_skills>\n";

/// Render the prompt component. An empty catalog renders nothing.
pub fn render(arena: std.mem.Allocator, entries: []const Entry) ![]const u8 {
    if (entries.len == 0) return "";
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, catalog_lead);
    for (entries) |entry| {
        std.debug.assert(nameFault(entry.name) == null);
        try out.appendSlice(arena, "  <skill>\n    <name>");
        try out.appendSlice(arena, entry.name);
        try out.appendSlice(arena, "</name>\n    <description>");
        try appendEscaped(arena, &out, entry.description);
        try out.appendSlice(arena, "</description>\n  </skill>\n");
    }
    try out.appendSlice(arena, "</available_skills>");
    return out.toOwnedSlice(arena);
}

fn appendEscaped(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |byte| {
        const escaped: ?[]const u8 = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => null,
        };
        if (escaped) |replacement| try out.appendSlice(arena, replacement) else try out.append(arena, byte);
    }
}

/// Report whether a fresh scan differs from `stored`. Both lists are sorted by name.
pub fn changed(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, workspace: []const u8, stored: []const Entry) error{ OutOfMemory, Canceled }!bool {
    const fresh = load(arena, io, env, workspace) catch |err| switch (err) {
        error.TooManySkills => return true,
        error.OutOfMemory, error.Canceled => |e| return e,
    };
    if (fresh.entries.len != stored.len) return true;
    for (fresh.entries, stored) |a, b| {
        if (a.scope != b.scope) return true;
        if (!std.mem.eql(u8, a.name, b.name) or !std.mem.eql(u8, a.description, b.description)) return true;
        if (!std.mem.eql(u8, a.path, b.path) or !std.mem.eql(u8, a.canonical_path, b.canonical_path)) return true;
    }
    return false;
}

const testing = std.testing;

const Roots = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    root_buf: [std.fs.max_path_bytes]u8,
    workspace: []const u8,

    fn init(self: *Roots) !void {
        self.tmp = testing.tmpDir(.{});
        self.arena = .init(testing.allocator);
        self.env = .init(testing.allocator);
        try self.tmp.dir.createDirPath(testing.io, "home/.agents/skills");
        try self.tmp.dir.createDirPath(testing.io, "work/.agents/skills");
        const root = self.root_buf[0..try self.tmp.dir.realPath(testing.io, &self.root_buf)];
        try self.env.put(if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME", try std.fs.path.join(self.arena.allocator(), &.{ root, "home" }));
        self.workspace = try std.fs.path.join(self.arena.allocator(), &.{ root, "work" });
    }

    fn deinit(self: *Roots) void {
        self.env.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn skill(self: *Roots, scope: []const u8, dir: []const u8, text: []const u8) !void {
        const sub = try std.fmt.allocPrint(self.arena.allocator(), "{s}/.agents/skills/{s}", .{ scope, dir });
        try self.tmp.dir.createDirPath(testing.io, sub);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.allocPrint(self.arena.allocator(), "{s}/SKILL.md", .{sub}), .data = text });
    }

    fn load(self: *Roots) !Catalog {
        return skills_load(self.arena.allocator(), testing.io, &self.env, self.workspace);
    }
};

const skills_load = load;

test "the catalog sorts names, prefers the workspace, and reports skipped files" {
    var r: Roots = undefined;
    try r.init();
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), (try r.load()).entries.len);
    try r.skill("home", "zeta", "---\nname: zeta\ndescription: global zeta\n---\nbody z");
    try r.skill("home", "shared", "---\ndescription: \"the global one\"\n---\n");
    try r.skill("work", "shared", "---\nname: shared\ndescription: 'the workspace one'\n---\n");
    try r.skill("work", "alpha", "---\ndescription: >\n  folded\n  text\nlicense: MIT\n---\n# Alpha\n");
    try r.skill("work", "no-description", "---\nname: no-description\n---\n");
    try r.skill("work", "Bad_Name", "---\ndescription: bad\n---\n");
    try r.skill("work", "plain", "no frontmatter here");
    try r.skill("work", "twin", "---\nname: alpha\ndescription: steals the name\n---\n");
    try r.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/.agents/skills/README.md", .data = "ignored" });
    const catalog = try r.load();
    try testing.expectEqual(@as(usize, 3), catalog.entries.len);
    try testing.expectEqualStrings("alpha", catalog.entries[0].name);
    try testing.expectEqualStrings("folded text", catalog.entries[0].description);
    try testing.expectEqual(.workspace, catalog.entries[0].scope);
    try testing.expectEqualStrings("shared", catalog.entries[1].name);
    try testing.expectEqualStrings("the workspace one", catalog.entries[1].description);
    try testing.expectEqual(.workspace, catalog.entries[1].scope);
    try testing.expectEqualStrings("zeta", catalog.entries[2].name);
    try testing.expectEqual(.global, catalog.entries[2].scope);
    try testing.expect(std.mem.endsWith(u8, catalog.entries[2].path, "home/.agents/skills/zeta/SKILL.md"));
    try testing.expectEqual(@as(usize, 5), catalog.skipped.len);
    const reasons = [_][]const u8{ "may only hold lowercase", "the description is missing", "no frontmatter", "already holds this name", "already holds this name" };
    for (catalog.skipped, reasons) |entry, reason| try testing.expect(std.mem.indexOf(u8, entry.reason, reason) != null);
    try testing.expect(std.mem.indexOf(u8, catalog.skipped[4].path, "home/.agents/skills/shared") != null);
    try testing.expect(!try changed(r.arena.allocator(), testing.io, &r.env, r.workspace, catalog.entries));
    try r.skill("work", "alpha", "---\ndescription: edited\n---\n");
    try testing.expect(try changed(r.arena.allocator(), testing.io, &r.env, r.workspace, catalog.entries));
}

test "a symlinked skill loads once and a body reads without its frontmatter" {
    var r: Roots = undefined;
    try r.init();
    defer r.deinit();
    const a = r.arena.allocator();
    try r.tmp.dir.createDirPath(testing.io, "shared-skill");
    try r.tmp.dir.writeFile(testing.io, .{ .sub_path = "shared-skill/SKILL.md", .data = "---\r\nname: shared\r\ndescription: |\r\n  literal\r\n  lines\r\n---\r\n\r\nUse scripts/run.sh.\r\n" });
    try r.tmp.dir.symLink(testing.io, "../../../shared-skill", "home/.agents/skills/shared", .{ .is_directory = true });
    try r.tmp.dir.symLink(testing.io, "../../../shared-skill", "work/.agents/skills/shared", .{ .is_directory = true });
    const catalog = try r.load();
    try testing.expectEqual(@as(usize, 1), catalog.entries.len);
    try testing.expectEqual(@as(usize, 0), catalog.skipped.len);
    try testing.expectEqual(.workspace, catalog.entries[0].scope);
    try testing.expectEqualStrings("literal\nlines", catalog.entries[0].description);
    try testing.expect(std.mem.endsWith(u8, catalog.entries[0].canonical_path, "shared-skill/SKILL.md"));
    const body = try readBody(a, testing.io, catalog.entries[0], null);
    try testing.expectEqualStrings("Use scripts/run.sh.", body.body);
    try testing.expect(std.mem.endsWith(u8, body.directory, "shared-skill"));
    const wrapped = try wrap(a, "shared", body);
    try testing.expect(std.mem.startsWith(u8, wrapped, "<skill_content name=\"shared\">\nUse scripts/run.sh.\n\nSkill directory: "));
    try testing.expect(std.mem.endsWith(u8, wrapped, "shared-skill\nResolve relative paths against this directory.\n</skill_content>"));
    const odd = try wrap(a, "shared", .{ .body = "Keep </skill_content> literal.", .directory = "/tmp/a&b<c>" });
    try testing.expectEqualStrings("<skill_content name=\"shared\">\nKeep </skill_content> literal.\n\nSkill directory: /tmp/a&amp;b&lt;c&gt;\nResolve relative paths against this directory.\n</skill_content>", odd);
    try r.tmp.dir.deleteFile(testing.io, "shared-skill/SKILL.md");
    var diagnostic: ?[]const u8 = null;
    try testing.expectError(error.SkillUnreadable, readBody(a, testing.io, catalog.entries[0], &diagnostic));
    try testing.expect(std.mem.indexOf(u8, diagnostic.?, "work/.agents/skills/shared/SKILL.md") != null);
}

test "the catalog skips invalid UTF-8 directory names and reports a valid path" {
    const Names = struct {
        fn read(userdata: ?*anyopaque, reader: *std.Io.Dir.Reader, entries: []std.Io.Dir.Entry) std.Io.Dir.Reader.Error!usize {
            const count = try testing.io.vtable.dirRead(userdata, reader, entries);
            for (entries[0..count]) |*entry| {
                if (std.mem.eql(u8, entry.name, "invalid-name")) entry.name = "\xff";
            }
            return count;
        }
    };
    var r: Roots = undefined;
    try r.init();
    defer r.deinit();
    try r.skill("work", "invalid-name", "---\ndescription: hidden name\n---\n");
    try r.skill("work", "visible", "---\ndescription: valid name\n---\n");
    // Inject the directory entry because some filesystems reject invalid UTF-8 names.
    var vtable = testing.io.vtable.*;
    vtable.dirRead = Names.read;
    const io: std.Io = .{ .userdata = testing.io.userdata, .vtable = &vtable };
    const catalog = try skills_load(r.arena.allocator(), io, &r.env, r.workspace);
    try testing.expectEqual(@as(usize, 1), catalog.entries.len);
    try testing.expectEqualStrings("visible", catalog.entries[0].name);
    try testing.expectEqual(@as(usize, 1), catalog.skipped.len);
    try testing.expectEqualStrings("a directory name is not valid UTF-8", catalog.skipped[0].reason);
    const root = try std.fs.path.join(r.arena.allocator(), &.{ r.workspace, ".agents", "skills" });
    try testing.expectEqualStrings(root, catalog.skipped[0].path);
    try testing.expect(std.unicode.utf8ValidateSlice(catalog.skipped[0].path));
}

test "an oversized skill is skipped and too many candidates refuse the root" {
    var r: Roots = undefined;
    try r.init();
    defer r.deinit();
    const a = r.arena.allocator();
    const large = try a.alloc(u8, max_file_bytes + 1);
    @memset(large, 'x');
    try r.skill("work", "big", large);
    const catalog = try r.load();
    try testing.expectEqual(@as(usize, 0), catalog.entries.len);
    try testing.expectEqual(@as(usize, 1), catalog.skipped.len);
    try testing.expectEqualStrings("the file exceeds 256 KiB", catalog.skipped[0].reason);
    // Exactly the bound loads; one more candidate refuses the root, even when the scan skips it.
    for (0..max_per_root - 1) |i| try r.skill("work", try std.fmt.allocPrint(a, "s{d:0>3}", .{i}), "---\ndescription: d\n---\n");
    try testing.expectEqual(@as(usize, max_per_root - 1), (try r.load()).entries.len);
    try r.skill("work", "zlast", "---\ndescription: d\n---\n");
    try testing.expectError(error.TooManySkills, r.load());
    try testing.expect(try changed(a, testing.io, &r.env, r.workspace, catalog.entries));
}

test "a root with too many entries stops before the scan sorts them" {
    var r: Roots = undefined;
    try r.init();
    defer r.deinit();
    const a = r.arena.allocator();
    for (0..max_root_entries - 1) |i| try r.tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "work/.agents/skills/f{d}", .{i}), .data = "" });
    try r.skill("work", "real", "---\ndescription: d\n---\n");
    try testing.expectEqual(@as(usize, 1), (try r.load()).entries.len);
    try r.tmp.dir.writeFile(testing.io, .{ .sub_path = "work/.agents/skills/one-more", .data = "" });
    try testing.expectError(error.TooManySkills, r.load());
}

test "the scan reads only the head of a file and the body read validates the whole file" {
    var r: Roots = undefined;
    try r.init();
    defer r.deinit();
    const a = r.arena.allocator();
    const filler = try a.alloc(u8, max_frontmatter_bytes);
    @memset(filler, 'y');
    try r.skill("work", "long", try std.mem.concat(a, u8, &.{ "---\ndescription: long body\n---\n", filler, "\n\xff" }));
    const catalog = try r.load();
    try testing.expectEqual(@as(usize, 1), catalog.entries.len);
    try testing.expectEqualStrings("long body", catalog.entries[0].description);
    var diagnostic: ?[]const u8 = null;
    try testing.expectError(error.SkillUnreadable, readBody(a, testing.io, catalog.entries[0], &diagnostic));
    try testing.expect(std.mem.indexOf(u8, diagnostic.?, "UTF-8") != null);
    try r.skill("work", "late", try std.mem.concat(a, u8, &.{ "---\n", filler, "\ndescription: too far\n---\n" }));
    const again = try r.load();
    try testing.expectEqual(@as(usize, 1), again.entries.len);
    try testing.expectEqualStrings("the file has no frontmatter", again.skipped[0].reason);
}

test "the prompt component escapes descriptions and vanishes for an empty catalog" {
    const a = testing.allocator;
    try testing.expectEqualStrings("", try render(a, &.{}));
    const entries = [_]Entry{.{ .name = "pdf", .description = "a <b> & \"c\"", .scope = .global, .path = "/p", .canonical_path = "/p" }};
    const text = try render(a, &entries);
    defer a.free(text);
    try testing.expectEqualStrings(catalog_lead ++ "  <skill>\n    <name>pdf</name>\n    <description>a &lt;b&gt; &amp; &quot;c&quot;</description>\n  </skill>\n</available_skills>", text);
}

test "name rules follow the specification" {
    try testing.expect(nameFault("pdf-processing") == null);
    try testing.expect(nameFault("a1") == null);
    try testing.expect(nameFault("") != null);
    try testing.expect(nameFault("PDF") != null);
    try testing.expect(nameFault("-pdf") != null);
    try testing.expect(nameFault("pdf-") != null);
    try testing.expect(nameFault("pdf--x") != null);
    try testing.expect(nameFault("x" ** 65) != null);
    try testing.expect(nameFault("x" ** 64) == null);
}

test "the frontmatter parser reads the subset and refuses the rest" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = (try parseFrontmatter(a, "---\n# comment\nname: \"quoted\"\nmetadata:\n  author: x\ndescription: plain: with colon # note\n---\nbody\n")).?;
    try testing.expectEqualStrings("quoted", parsed.name.?);
    try testing.expectEqualStrings("plain: with colon", parsed.description.?);
    try testing.expectEqualStrings("body", parsed.body);
    try testing.expect((try parseFrontmatter(a, "name: x\n---\n")) == null);
    try testing.expect((try parseFrontmatter(a, "---\nname: x\n")) == null);
    try testing.expectEqualStrings("---\nnot frontmatter", (try parseFrontmatter(a, "---\nname: x\n---\n---\nnot frontmatter\n")).?.body);
    const block = (try parseFrontmatter(a, "---\ndescription: >-\n  one\n\n  two\n   more\n  three\nname: block\n---\n")).?;
    try testing.expectEqualStrings("one\ntwo\n more\nthree", block.description.?);
    try testing.expectEqualStrings("block", block.name.?);
    try testing.expectEqualStrings("", block.body);
    const literal = (try parseFrontmatter(a, "---\ndescription: |+\n  one\n\n  two\n\n\nname: literal\n---\n")).?;
    try testing.expectEqualStrings("one\n\ntwo", literal.description.?);
    try testing.expectEqualStrings("literal", literal.name.?);
    try testing.expectEqualStrings("one two\n", (try blockScalar(a, "  one\n  two\n", .{ .folded = true, .chomp = .clip })));
    try testing.expectEqualStrings("one\ntwo", (try blockScalar(a, "  one\n  two\n\n", .{ .folded = false, .chomp = .strip })));
    try testing.expectEqualStrings("one two\n\n\n", (try blockScalar(a, "  one\n  two\n\n\n", .{ .folded = true, .chomp = .keep })));
    try testing.expectEqualStrings("one two", (try blockScalar(a, "  one\n  two", .{ .folded = true, .chomp = .clip })));
    // A shallower or tab-indented line ends the block instead of losing its first bytes.
    try testing.expectEqualStrings("first", (try blockScalar(a, "   first\n  second\n", .{ .folded = true, .chomp = .strip })));
    try testing.expectEqualStrings("one", (try blockScalar(a, "  one\n\ttwo\n", .{ .folded = true, .chomp = .strip })));
    try testing.expectEqualStrings("", (try blockScalar(a, "\ttwo\n", .{ .folded = true, .chomp = .strip })));
    try testing.expectEqualStrings("Use \"x\"\tnow", try scalar(a, "\"Use \\\"x\\\"\\tnow\" # trailing"));
    try testing.expectEqualStrings("A\u{e9}\u{1F600}", try scalar(a, "\"\\x41\\u00e9\\U0001F600\""));
    try testing.expectEqualStrings("\"bad\\x4", try scalar(a, "\"bad\\x4"));
    try testing.expectEqualStrings("\"text\\", try scalar(a, "\"text\\"));
    try testing.expectEqualStrings("it's", try scalar(a, "'it''s'"));
    try testing.expectEqualStrings("\"unterminated", try scalar(a, "\"unterminated"));
    try testing.expectEqualStrings("[text]", try scalar(a, "[text]"));
    try testing.expectEqualStrings("a#b", try scalar(a, "a#b"));
    try testing.expect(descriptionFault("tab\tand\nline") == null);
    try testing.expect(descriptionFault("bell\x07") != null);
    try testing.expect(descriptionFault("\xff") != null);
}
