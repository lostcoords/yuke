const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The wire package. Standalone for now; the daemon and client will import it.
    const wire = b.addModule("wire", .{
        .root_source_file = b.path("src/wire/wire.zig"),
        .target = target,
        .optimize = optimize,
    });
    const wire_tests = b.addTest(.{
        .root_module = wire,
    });
    const run_wire_tests = b.addRunArtifact(wire_tests);

    const wiregen = b.createModule(.{
        .root_source_file = b.path("tools/wiregen/gen.zig"),
        .target = target,
        .optimize = optimize,
    });
    wiregen.addImport("wire", wire);

    const gen_schema = b.addExecutable(.{
        .name = "gen-schema",
        .root_module = wiregen,
    });
    const run_gen_schema = b.addRunArtifact(gen_schema);
    run_gen_schema.setCwd(b.path("."));

    const test_step = b.step("test", "Run wire tests");
    test_step.dependOn(&run_wire_tests.step);

    // Regenerate schema/wire.json in place from the Zig wire types.
    const write_schema = b.addUpdateSourceFiles();
    write_schema.addCopyFileToSource(run_gen_schema.captureStdOut(.{}), "schema/wire.json");
    const gen_schema_step = b.step("gen-schema", "Regenerate schema/wire.json from the wire types");
    gen_schema_step.dependOn(&write_schema.step);
}
