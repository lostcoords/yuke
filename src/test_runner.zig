//! The runner of the `src` test binary: `--shard=i/n` runs every n-th test, so n processes share one compile.

const builtin = @import("builtin");
const std = @import("std");

const Io = std.Io;
const testing = std.testing;

pub const std_options: std.Options = .{ .logFn = log };

var log_err_count: usize = 0;
var args_buffer: [4096]u8 = undefined;
var stdin_buffer: [4096]u8 = undefined;
var stdout_buffer: [4096]u8 = undefined;
const runner_io: Io = Io.Threaded.global_single_threaded.io();

/// The tests of one shard, as indexes into `builtin.test_functions`.
const Shard = struct {
    index: u32 = 0,
    count: u32 = 1,

    fn parse(text: []const u8) ?Shard {
        const slash = std.mem.indexOfScalar(u8, text, '/') orelse return null;
        const index = std.fmt.parseUnsigned(u32, text[0..slash], 10) catch return null;
        const count = std.fmt.parseUnsigned(u32, text[slash + 1 ..], 10) catch return null;
        if (count == 0 or index >= count) return null;
        return .{ .index = index, .count = count };
    }

    fn len(self: Shard) u32 {
        const total: u32 = @intCast(builtin.test_functions.len);
        return (total + self.count - 1 - self.index) / self.count;
    }

    fn testIndex(self: Shard, i: u32) u32 {
        std.debug.assert(i < self.len());
        return self.index + i * self.count;
    }
};

pub fn main(init: std.process.Init.Minimal) void {
    var fba: std.heap.FixedBufferAllocator = .init(&args_buffer);
    const args = init.args.toSlice(fba.allocator()) catch @panic("the test arguments do not fit");
    var listen = false;
    var shard: Shard = .{};
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) {
            listen = true;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch @panic("the seed is not a number");
        } else if (std.mem.startsWith(u8, arg, "--shard=")) {
            shard = Shard.parse(arg["--shard=".len..]) orelse @panic("the shard must be i/n with i < n");
        } else if (!std.mem.startsWith(u8, arg, "--cache-dir=")) {
            std.debug.panic("unknown test runner argument: {s}", .{arg});
        }
    }
    if (listen) return mainServer(init, shard) catch |err| std.debug.panic("test runner failure: {t}", .{err});
    mainTerminal(init, shard);
}

/// Serve the build runner: it asks for the test names, then runs each test by its index in that list.
fn mainServer(init: std.process.Init.Minimal, shard: Shard) !void {
    var stdin_reader: Io.File.Reader = .initStreaming(.stdin(), runner_io, &stdin_buffer);
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), runner_io, &stdout_buffer);
    var server = try std.zig.Server.init(.{
        .in = &stdin_reader.interface,
        .out = &stdout_writer.interface,
        .zig_version = builtin.zig_version_string,
    });
    while (true) {
        const header = try server.receiveMessage();
        switch (header.tag) {
            .exit => return std.process.exit(0),
            .query_test_metadata => {
                var gpa: std.heap.DebugAllocator(.{}) = .init;
                defer std.debug.assert(gpa.deinit() == .ok);
                const a = gpa.allocator();
                var string_bytes: std.ArrayList(u8) = .empty;
                defer string_bytes.deinit(a);
                try string_bytes.append(a, 0);
                const names = try a.alloc(u32, shard.len());
                defer a.free(names);
                const expected_panic_msgs = try a.alloc(u32, shard.len());
                defer a.free(expected_panic_msgs);
                @memset(expected_panic_msgs, 0);
                for (names, 0..) |*name, i| {
                    name.* = @intCast(string_bytes.items.len);
                    try string_bytes.appendSlice(a, builtin.test_functions[shard.testIndex(@intCast(i))].name);
                    try string_bytes.append(a, 0);
                }
                try server.serveTestMetadata(.{ .names = names, .expected_panic_msgs = expected_panic_msgs, .string_bytes = string_bytes.items });
            },
            .run_test => {
                const index = try server.receiveBody_u32();
                try server.serveStringMessage(.test_started, &.{});
                const outcome = runTest(init, shard.testIndex(index));
                try server.serveTestResults(.{ .index = index, .flags = .{
                    .status = outcome.status,
                    .fuzz = false,
                    .log_err_count = std.math.lossyCast(@FieldType(std.zig.Server.Message.TestResults.Flags, "log_err_count"), log_err_count),
                    .leak_count = std.math.lossyCast(@FieldType(std.zig.Server.Message.TestResults.Flags, "leak_count"), outcome.leaks),
                } });
            },
            else => std.debug.panic("unsupported build runner message: {x}", .{@intFromEnum(header.tag)}),
        }
    }
}

const Outcome = struct { status: std.zig.Server.Message.TestResults.Status, leaks: usize };

/// Run one test with a fresh testing allocator and I/O, as the default runner does.
fn runTest(init: std.process.Init.Minimal, index: u32) Outcome {
    testing.environ = init.environ;
    testing.allocator_instance = .{};
    testing.io_instance = .init(testing.allocator, .{ .argv0 = .init(init.args), .environ = init.environ });
    log_err_count = 0;
    const status: std.zig.Server.Message.TestResults.Status = if (builtin.test_functions[index].func()) |_| .pass else |err| switch (err) {
        error.SkipZigTest => .skip,
        else => blk: {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            break :blk .fail;
        },
    };
    testing.io_instance.deinit();
    const leaks = testing.allocator_instance.detectLeaks();
    testing.allocator_instance.deinitWithoutLeakChecks();
    return .{ .status = status, .leaks = leaks };
}

/// Run the shard in a terminal and print each test with its time, which shows where the suite spends it.
fn mainTerminal(init: std.process.Init.Minimal, shard: Shard) void {
    var failed: usize = 0;
    for (0..shard.len()) |i| {
        const index = shard.testIndex(@intCast(i));
        const started: Io.Timestamp = .now(runner_io, .awake);
        const outcome = runTest(init, index);
        const ms = started.durationTo(.now(runner_io, .awake)).toMilliseconds();
        const bad = outcome.status == .fail or outcome.leaks != 0 or log_err_count != 0;
        if (bad) failed += 1;
        std.debug.print("{d:>6} ms {t} {s}\n", .{ ms, if (bad) .fail else outcome.status, builtin.test_functions[index].name });
    }
    std.debug.print("{d} of {d} tests failed\n", .{ failed, shard.len() });
    if (failed != 0) std.process.exit(1);
}

pub fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (@intFromEnum(level) <= @intFromEnum(std.log.Level.err)) log_err_count +|= 1;
    if (@intFromEnum(level) <= @intFromEnum(testing.log_level)) {
        std.debug.print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(level) ++ "): " ++ format ++ "\n", args);
    }
}
