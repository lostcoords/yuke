//! Compile the baked JavaScript modules to QuickJS bytecode. A host then reads them and parses nothing.

const std = @import("std");
const quickjs = @import("quickjs");

const usage = "usage: yuke-jsbake <out-dir> <native-names> (<module-name> <source-path>)...";

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.log.err("jsbake failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 5 or args.len % 2 != 1) {
        std.log.err("{s}", .{usage});
        std.process.exit(2);
    }
    const out_dir = args[1];
    const native = args[2];
    const pairs = args[3..];
    const count = pairs.len / 2;

    var compiler: Compiler = .{ .gpa = a, .native = native, .sources = .empty, .modules = .empty };
    const cwd = std.Io.Dir.cwd();
    for (0..count) |k| {
        const source = try cwd.readFileAllocOptions(init.io, pairs[2 * k + 1], a, .unlimited, .of(u8), 0);
        try compiler.sources.put(a, pairs[2 * k], source);
    }

    const runtime = try quickjs.Runtime.init(std.heap.smp_allocator);
    defer runtime.deinit();
    const ctx = quickjs.Context.init(runtime);
    defer ctx.deinit();
    runtime.setModuleLoader(&compiler);

    // One root imports every module, so resolution compiles each one exactly once.
    var root: std.Io.Writer.Allocating = .init(a);
    for (0..count) |k| try root.writer.print("import \"{s}\";\n", .{pairs[2 * k]});
    const root_value = ctx.eval(try a.dupeZ(u8, root.written()), "jsbake-root", .{ .type = .module, .compile_only = true }) catch {
        reportException(ctx);
        return error.CompileFailed;
    };
    ctx.freeValue(root_value);

    var zig: std.Io.Writer.Allocating = .init(a);
    try zig.writer.writeAll(
        \\//! tools/jsbake wrote this file. Each entry holds the QuickJS bytecode of one baked module.
        \\
        \\pub const Module = struct { name: []const u8, bytecode: []const u8 };
        \\
        \\pub const modules = [_]Module{
        \\
    );
    for (0..count) |k| {
        const name = pairs[2 * k];
        const module = compiler.modules.get(name) orelse return error.ModuleNotCompiled;
        // Drop only the source text, which no caller but `Function.prototype.toString` reads.
        const bytecode = try ctx.writeObject(module, .{ .bytecode = true, .strip_source = true });
        defer ctx.free(bytecode.ptr);
        const file = try std.fmt.allocPrint(a, "{d}.qbc", .{k});
        try cwd.writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ out_dir, file }), .data = bytecode });
        try zig.writer.print("    .{{ .name = \"{s}\", .bytecode = @embedFile(\"{s}\") }},\n", .{ name, file });
    }
    try zig.writer.writeAll("};\n\n/// The native modules a host installs. The bake accepts an import of these names and no other.\npub const native = [_][]const u8{\n");
    var names = std.mem.splitScalar(u8, native, ',');
    while (names.next()) |name| try zig.writer.print("    \"{s}\",\n", .{name});
    try zig.writer.writeAll("};\n");
    try cwd.writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ out_dir, "baked.zig" }), .data = zig.written() });

    var it = compiler.modules.valueIterator();
    while (it.next()) |module| ctx.freeValue(module.*);
}

/// The loader compiles a baked module on its first import. The value stays until `run` writes the bytecode.
const Compiler = struct {
    gpa: std.mem.Allocator,
    /// The native module names, comma separated. Any other unknown import fails the bake.
    native: []const u8,
    sources: std.StringHashMapUnmanaged([:0]const u8),
    modules: std.StringHashMapUnmanaged(quickjs.Value),

    pub fn onLoadModule(self: *Compiler, ctx: quickjs.Context, name: []const u8) ?quickjs.Context.Module {
        const entry = self.sources.getEntry(name) orelse {
            // A native module lives only in a host, so a stub with no exports satisfies resolution.
            if (self.isNative(name)) return ctx.newModule(name, nativeStub);
            // QuickJS sets no exception for a null answer, so the bake names the unknown module itself.
            var message: [512]u8 = undefined;
            const text = std.fmt.bufPrintZ(&message, "could not load module '{s}'", .{name}) catch "could not load a module with a long name";
            _ = ctx.throwReferenceError(text);
            return null;
        };
        const filename = self.gpa.dupeZ(u8, name) catch return null;
        const value = ctx.eval(entry.value_ptr.*, filename, .{ .type = .module, .compile_only = true }) catch return null;
        // QuickJS frees the `name` buffer after this call, so the key comes from the source table.
        self.modules.putNoClobber(self.gpa, entry.key_ptr.*, ctx.dupValue(value)) catch return null;
        return ctx.moduleFromValue(value);
    }

    fn isNative(self: *const Compiler, name: []const u8) bool {
        var names = std.mem.splitScalar(u8, self.native, ',');
        while (names.next()) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
        return false;
    }
};

fn nativeStub(_: quickjs.Context, _: quickjs.Context.Module) c_int {
    return 0;
}

fn reportException(ctx: quickjs.Context) void {
    const exception = ctx.getException();
    defer ctx.freeValue(exception);
    const stack = ctx.getPropertyStr(exception, "stack");
    defer ctx.freeValue(stack);
    const message = ctx.toCStringLen(exception) catch return;
    defer ctx.freeCString(message.ptr);
    const trace = if (ctx.isString(stack)) ctx.toCStringLen(stack) catch null else null;
    defer if (trace) |t| ctx.freeCString(t.ptr);
    std.log.err("{s}\n{s}", .{ message, if (trace) |t| t else "" });
}
