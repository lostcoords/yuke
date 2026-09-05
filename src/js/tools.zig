//! The tools `index.js` registered. Each one owns a live JavaScript handler.
//!
//! The table stays sorted by name, so the load order of a plugin never moves the advertised prefix.
//!
//! The host owns this table, so a handler stays reachable for the life of the context.
//! A plugin registers and withdraws a tool at any time, and the engine asks for the set.
//!
//! A turn task submits a `Call` and waits. The OWNER runs the handler, polls the Promise, and
//! answers. No engine task ever enters QuickJS. The executor is cooperative and holds one thread,
//! so a task mutates the queue only between suspension points, and the two sides never interleave.

const std = @import("std");
const quickjs = @import("quickjs");
const zio = @import("zio");
const ir = @import("ai").ir;
const utf8 = @import("../utf8.zig");

const Context = quickjs.Context;
const Value = quickjs.Value;

/// The longest name a provider accepts. Anthropic states `^[a-zA-Z0-9_-]{1,64}$`, and OpenAI
/// accepts the same shape, so one rule covers both.
pub const max_name_bytes: usize = 64;

/// Why one registration was refused. Each case answers one sentence to the script.
pub const RegisterError = error{
    DuplicateName,
    InvalidName,
};

/// The registered tools, sorted by name. `decls[i]` is what the provider sees and `handlers[i]` is its GC root.
pub const Tools = struct {
    gpa: std.mem.Allocator,
    decls: std.ArrayList(ir.Tool) = .empty,
    handlers: std.ArrayList(Value) = .empty,

    pub fn deinit(self: *Tools, ctx: Context) void {
        for (self.decls.items, self.handlers.items) |decl, handler| {
            ctx.freeValue(handler);
            self.freeDecl(decl);
        }
        self.decls.deinit(self.gpa);
        self.handlers.deinit(self.gpa);
        self.* = undefined;
    }

    fn freeDecl(self: *Tools, decl: ir.Tool) void {
        self.gpa.free(decl.name);
        self.gpa.free(decl.description);
        self.gpa.free(decl.input_schema);
    }

    /// Add one tool. The table copies the text and takes the handler reference on success only.
    ///
    /// `JS_ToCStringLen` writes WTF-8 for a lone surrogate, so the copies become valid UTF-8 here.
    /// These strings reach a provider request, which accepts text and refuses a byte array.
    pub fn register(self: *Tools, name: []const u8, description: []const u8, input_schema: []const u8, handler: Value) RegisterError!void {
        if (!validName(name)) return error.InvalidName;
        const slot = self.lookup(name);
        if (slot.found) return error.DuplicateName;

        // The provider caches on the request prefix, so the advertised order must not follow load order.
        self.decls.insert(self.gpa, slot.at, .{
            .name = self.gpa.dupe(u8, name) catch unreachable,
            .description = utf8.sanitize(self.gpa, description) catch unreachable,
            .input_schema = utf8.sanitize(self.gpa, input_schema) catch unreachable,
        }) catch unreachable;
        self.handlers.insert(self.gpa, slot.at, handler) catch unreachable;
    }

    /// Where `name` sits in the sorted table, and whether a tool already holds it.
    const Lookup = struct { at: usize, found: bool };

    /// One ordered scan answers the insert position and the duplicate question together.
    fn lookup(self: *const Tools, name: []const u8) Lookup {
        std.debug.assert(self.decls.items.len == self.handlers.items.len);
        for (self.decls.items, 0..) |decl, i| {
            switch (std.mem.order(u8, name, decl.name)) {
                .lt => return .{ .at = i, .found = false },
                .eq => return .{ .at = i, .found = true },
                .gt => {},
            }
        }
        return .{ .at = self.decls.items.len, .found = false };
    }

    /// Return the index of the tool with `name`, or null.
    pub fn find(self: *const Tools, name: []const u8) ?usize {
        const slot = self.lookup(name);
        return if (slot.found) slot.at else null;
    }

    /// Remove the tool named `name` and answer false when no tool holds it.
    pub fn remove(self: *Tools, ctx: Context, name: []const u8) bool {
        const slot = self.lookup(name);
        if (!slot.found) return false;

        // Ordered, so the sorted advertisement holds.
        self.freeDecl(self.decls.orderedRemove(slot.at));
        ctx.freeValue(self.handlers.orderedRemove(slot.at));
        return true;
    }
};

/// What one call asks for. The kind selects the handler the owner runs and the answer it records.
pub const Kind = enum { tool, hook };

/// One call in flight. A turn task submits it and waits; the owner answers it.
///
/// The submitter touches no QuickJS value, so it never frees the Promise. It marks itself done,
/// and the owner sweeps the record on its next pass.
pub const Call = struct {
    kind: Kind = .tool,
    /// The tool name, or the hook point. The submitter owns these bytes for the whole call.
    name: []const u8,
    /// The tool arguments, or the hook payload. Raw JSON either way.
    arguments: []const u8,
    /// The workspace a tool runs against. A hook call leaves it empty.
    workspace_root: []u8,
    /// The submitter sleeps on this. The owner sets it once, when the call settles.
    done: zio.ResetEvent = .init,
    /// The answer text, from the host allocator. The submitter copies it before it leaves.
    text: ?[]u8 = null,
    /// A structured view encoded as JSON. The submitter decodes it in its turn arena.
    view_json: ?[]u8 = null,
    is_error: bool = false,
    /// The handler's Promise while it runs. Only the owner touches it.
    promise: Value = quickjs.UNDEFINED,
    /// The signal the handler reads. The owner sets `aborted` on it when the submitter leaves.
    signal: Value = quickjs.UNDEFINED,
    state: State = .queued,
    /// True after the submitter read its answer or left. The record is then the owner's to free.
    submitter_done: bool = false,

    pub const State = enum { queued, running, settled };

    /// Record the answer and wake the submitter. Only the owner calls this.
    pub fn settle(self: *Call, text: ?[]u8, is_error: bool) void {
        std.debug.assert(self.state != .settled); // one call settles one time
        self.text = text;
        self.is_error = is_error;
        self.state = .settled;
        self.done.set();
    }

    pub fn settleView(self: *Call, text: ?[]u8, view_json: []u8) void {
        std.debug.assert(self.state != .settled); // one call settles one time
        self.text = text;
        self.view_json = view_json;
        self.is_error = false;
        self.state = .settled;
        self.done.set();
    }

    /// Leave one call. The submitter calls this, so it frees nothing and enters no JavaScript.
    pub fn finish(self: *Call) void {
        std.debug.assert(!self.submitter_done); // one submitter leaves one time
        self.submitter_done = true;
    }
};

/// Every call the owner has not swept. The host owns it beside the table.
pub const Calls = struct {
    gpa: std.mem.Allocator,
    live: std.ArrayList(*Call) = .empty,

    /// Free every record. `Host.close` settles the waiting calls first, so nothing waits after this.
    pub fn deinit(self: *Calls, ctx: Context) void {
        for (self.live.items) |call| self.free(ctx, call);
        self.live.deinit(self.gpa);
        self.* = undefined;
    }

    /// Queue one call. This runs on a turn task, so it enters no JavaScript.
    pub fn submit(self: *Calls, name: []const u8, arguments: []const u8, workspace_root: []const u8) *Call {
        return self.submitCall(.tool, name, arguments, workspace_root);
    }

    /// Queue one hook question. The point names it, and the payload is the JSON that point defines.
    pub fn submitHook(self: *Calls, point: []const u8, payload: []const u8) *Call {
        return self.submitCall(.hook, point, payload, "");
    }

    fn submitCall(self: *Calls, kind: Kind, name: []const u8, arguments: []const u8, workspace_root: []const u8) *Call {
        const call = self.gpa.create(Call) catch unreachable;
        const root = self.gpa.dupe(u8, workspace_root) catch unreachable;
        call.* = .{ .kind = kind, .name = name, .arguments = arguments, .workspace_root = root };
        self.live.append(self.gpa, call) catch unreachable;
        return call;
    }

    /// Free every record the submitter left. Only the owner calls this, because it frees a Promise.
    /// A handler that still runs keeps its own references; this drops only the root the call held.
    pub fn sweep(self: *Calls, ctx: Context) void {
        var i: usize = 0;
        while (i < self.live.items.len) {
            const call = self.live.items[i];
            if (!call.submitter_done) {
                i += 1;
                continue;
            }
            // The handler keeps its own reference to the signal, so it reads this after the sweep.
            if (!ctx.isUndefined(call.signal)) {
                ctx.setPropertyStr(call.signal, "aborted", quickjs.TRUE) catch {};
            }
            // `orderedRemove` shifts the tail left, so `i` must NOT advance here.
            _ = self.live.orderedRemove(i);
            self.free(ctx, call);
        }
    }

    /// Report whether the owner has work. A queued call needs a start, a running call needs a poll
    /// while JavaScript still has jobs, and a left call needs a sweep.
    pub fn hasWork(self: *const Calls, jobs_pending: bool) bool {
        for (self.live.items) |call| {
            if (call.submitter_done) return true;
            switch (call.state) {
                .queued => return true,
                .running => if (jobs_pending) return true,
                .settled => {},
            }
        }
        return false;
    }

    fn free(self: *Calls, ctx: Context, call: *Call) void {
        ctx.freeValue(call.promise);
        ctx.freeValue(call.signal);
        if (call.text) |text| self.gpa.free(text);
        if (call.view_json) |json| self.gpa.free(json);
        self.gpa.free(call.workspace_root);
        self.gpa.destroy(call);
    }
};

/// Answer whether a provider accepts this name. Both providers state `^[a-zA-Z0-9_-]{1,64}$`.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

const testing = std.testing;

test "a name follows the pattern every provider states" {
    try testing.expect(validName("get_weather"));
    try testing.expect(validName("github-list-prs"));
    try testing.expect(validName("a"));
    try testing.expect(validName("A9"));

    try testing.expect(!validName("")); // a tool must have a name
    try testing.expect(!validName("get weather")); // a space is not in the set
    try testing.expect(!validName("get.weather"));
    try testing.expect(!validName("caf\u{e9}")); // one non-ASCII character
    try testing.expect(!validName("x" ** (max_name_bytes + 1)));
    try testing.expect(validName("x" ** max_name_bytes));
}

/// Open a bare runtime and context. The table frees a handler through a context, so a test needs one.
const Bare = struct {
    runtime: *quickjs.Runtime,
    ctx: Context,

    fn open() !Bare {
        const runtime = try quickjs.Runtime.init(testing.allocator);
        return .{ .runtime = runtime, .ctx = Context.init(runtime) };
    }
    fn close(self: *Bare) void {
        self.ctx.deinit();
        self.runtime.deinit();
    }
};

test "the table refuses a duplicate name, a bad name, and a late registration" {
    var bare = try Bare.open();
    defer bare.close();
    var tools: Tools = .{ .gpa = testing.allocator };
    defer tools.deinit(bare.ctx);

    try tools.register("probe", "a test tool", "{\"type\":\"object\"}", quickjs.UNDEFINED);
    try testing.expectError(error.DuplicateName, tools.register("probe", "d", "{}", quickjs.UNDEFINED));
    try testing.expectError(error.InvalidName, tools.register("bad name", "d", "{}", quickjs.UNDEFINED));

    // A tool registers at any time, so a plugin can add one after boot.
    try tools.register("late", "d", "{}", quickjs.UNDEFINED);
}

test "the declarations follow the registered tools" {
    var bare = try Bare.open();
    defer bare.close();
    var tools: Tools = .{ .gpa = testing.allocator };
    defer tools.deinit(bare.ctx);

    // Register out of order, because the load order of a plugin must not move the sorted prefix.
    try tools.register("beta", "the second", "{\"type\":\"object\",\"properties\":{}}", quickjs.UNDEFINED);
    try tools.register("alpha", "the first", "{\"type\":\"object\"}", quickjs.UNDEFINED);
    try tools.register("gamma", "the third", "{\"type\":\"object\"}", quickjs.UNDEFINED);

    try testing.expectEqual(@as(usize, 3), tools.decls.items.len);
    try testing.expectEqualStrings("alpha", tools.decls.items[0].name);
    try testing.expectEqualStrings("beta", tools.decls.items[1].name);
    try testing.expectEqualStrings("gamma", tools.decls.items[2].name);
    try testing.expectEqualStrings("the second", tools.decls.items[1].description);
    try testing.expectEqualStrings("{\"type\":\"object\",\"properties\":{}}", tools.decls.items[1].input_schema);
    try testing.expectEqual(@as(?usize, 1), tools.find("beta"));
    try testing.expect(tools.find("delta") == null);
}
