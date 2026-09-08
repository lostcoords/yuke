//! JSONL reports for the same scenarios that the process tests execute.

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const bench = @import("js/bench.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var scale: u32 = 1;
    var iterations: u32 = 100;
    var selected: ?bench.Phase = null;
    var fixture_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 == args.len) return error.MissingArgument;
        const arg = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, arg, "--scale")) {
            scale = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            iterations = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--phase")) {
            selected = std.meta.stringToEnum(bench.Phase, value) orelse return error.InvalidPhase;
        } else if (std.mem.eql(u8, arg, "--fixture")) {
            fixture_path = value;
        } else return error.UnknownArgument;
    }
    if (scale == 0 or iterations == 0) return error.InvalidCount;

    const runtime = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer runtime.deinit();
    const io = runtime.io();
    const fixture = if (fixture_path) |path|
        try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024))
    else
        try gpa.dupe(u8, "");
    defer gpa.free(fixture);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture, &digest, .{});
    const fixture_hash = std.fmt.bytesToHex(digest, .lower);
    const samples = try gpa.alloc(u64, iterations);
    defer gpa.free(samples);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &buffer);

    for (bench.phases) |phase| {
        if (selected) |chosen| if (chosen != phase) continue;
        const harness = try bench.Harness.create(gpa, io, fixture, 100, 40);
        defer harness.destroy();
        for (0..5) |repeat| {
            try harness.start(phase, scale);
            const before = harness.allocations.counts;
            var output_bytes: u64 = 0;
            for (samples) |*sample| {
                const start = std.Io.Timestamp.now(io, .awake);
                output_bytes += try harness.step();
                sample.* = @intCast(start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
            }
            const allocations = harness.allocations.counts.since(before);
            const live_bytes = harness.allocations.liveBytes();
            const peak_bytes = harness.allocations.peak_bytes;
            const counters = harness.counters();
            const usage = harness.host.runtime.computeMemoryUsage();
            const checksum = try harness.verify();
            std.mem.sort(u64, samples, {}, std.sort.asc(u64));
            try std.json.Stringify.value(.{
                .phase = @tagName(phase),
                .repeat = repeat,
                .scale = scale,
                .iterations = iterations,
                .fixture = fixture_path orelse "synthetic",
                .fixture_sha256 = fixture_hash[0..],
                .zig_version = builtin.zig_version_string,
                .optimize = @tagName(builtin.mode),
                .metrics = bench.metrics_enabled,
                .median_ns = samples[samples.len / 2],
                .p95_ns = samples[(samples.len - 1) * 95 / 100],
                .max_ns = samples[samples.len - 1],
                .checksum = checksum,
                .output_bytes = output_bytes,
                .js_estimated_bytes = usage.memory_used_size,
                .js_tracked_bytes = usage.malloc_size,
                .backing_live_bytes = if (bench.metrics_enabled) live_bytes else null,
                .backing_peak_bytes = if (bench.metrics_enabled) peak_bytes else null,
                .allocations = if (bench.metrics_enabled) allocations else null,
                .ui = if (bench.metrics_enabled) counters else null,
            }, .{}, &output.interface);
            try output.interface.writeByte('\n');
            try output.interface.flush();
        }
    }
}
