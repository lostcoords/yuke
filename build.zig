const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });
    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });
    const sql = b.addModule("sql", .{
        .root_source_file = b.path("packages/sql/sql.zig"),
        .target = target,
        .optimize = optimize,
    });
    sql.addImport("zqlite", zqlite.module("zqlite"));
    const sql_tests = b.addTest(.{
        .root_module = sql,
    });
    const run_sql_tests = b.addRunArtifact(sql_tests);
    const test_sql_step = b.step("test-sql", "Run SQL package tests");
    test_sql_step.dependOn(&run_sql_tests.step);

    const sqlgen = b.createModule(.{
        .root_source_file = b.path("tools/sqlgen/sqlgen.zig"),
        .target = target,
        .optimize = optimize,
    });
    sqlgen.addImport("zqlite", zqlite.module("zqlite"));
    const sqlgen_tests = b.addTest(.{
        .root_module = sqlgen,
    });
    const run_sqlgen_tests = b.addRunArtifact(sqlgen_tests);

    const sqlgen_cli = b.createModule(.{
        .root_source_file = b.path("tools/sqlgen/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    sqlgen_cli.addImport("sqlgen", sqlgen);
    sqlgen_cli.addImport("zqlite", zqlite.module("zqlite"));
    const sqlgen_exe = b.addExecutable(.{
        .name = "yuke-sqlgen",
        .root_module = sqlgen_cli,
    });
    const run_sqlgen = b.addRunArtifact(sqlgen_exe);
    if (b.args) |args| run_sqlgen.addArgs(args);
    const sqlgen_step = b.step("sqlgen", "Validate SQL and generate typed queries");
    sqlgen_step.dependOn(&run_sqlgen.step);

    const test_sqlgen_step = b.step("test-sqlgen", "Run SQL generator tests");
    test_sqlgen_step.dependOn(&run_sqlgen_tests.step);

    // The wire package: the authoritative protocol types. Standalone, no deps.
    const wire = b.addModule("wire", .{
        .root_source_file = b.path("packages/wire/wire.zig"),
        .target = target,
        .optimize = optimize,
    });
    const wire_tests = b.addTest(.{
        .root_module = wire,
    });
    const run_wire_tests = b.addRunArtifact(wire_tests);
    const test_wire_step = b.step("test-wire", "Run wire package tests");
    test_wire_step.dependOn(&run_wire_tests.step);

    // The WebSocket package implements sans-IO RFC 6455 framing and has no dependencies.
    const websocket = b.addModule("websocket", .{
        .root_source_file = b.path("packages/websocket/websocket.zig"),
        .target = target,
        .optimize = optimize,
    });
    const websocket_tests = b.addTest(.{
        .root_module = websocket,
    });
    const run_websocket_tests = b.addRunArtifact(websocket_tests);
    const test_websocket_step = b.step("test-websocket", "Run websocket package tests");
    test_websocket_step.dependOn(&run_websocket_tests.step);

    const tests = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.addImport("wire", wire);
    tests.addImport("sql", sql);
    tests.addImport("zqlite", zqlite.module("zqlite"));
    const layer_tests = b.addTest(.{
        .root_module = tests,
    });
    const run_layer_tests = b.addRunArtifact(layer_tests);

    // Fail the build if the committed queries drift from the SQL sources.
    const database_sqlgen_check = b.addRunArtifact(sqlgen_exe);
    database_sqlgen_check.addArgs(&.{
        "--migrations",  "src/database/migrations",
        "--queries",     "src/database/queries",
        "--queries-out", "src/database/queries_gen.zig",
        "--check",
    });
    database_sqlgen_check.setCwd(b.path("."));

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

    // Build the daemon executable with the zio reactor and front door.
    const daemon_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    daemon_mod.addImport("zio", zio.module("zio"));
    daemon_mod.addImport("websocket", websocket);
    daemon_mod.addImport("wire", wire);
    const daemon_exe = b.addExecutable(.{
        .name = "yuked",
        .root_module = daemon_mod,
    });
    b.installArtifact(daemon_exe);
    const run_daemon = b.addRunArtifact(daemon_exe);
    if (b.args) |args| run_daemon.addArgs(args);
    const run_daemon_step = b.step("run-daemon", "Run the yuke daemon");
    run_daemon_step.dependOn(&run_daemon.step);

    const daemon_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon/http.zig"),
        .target = target,
        .optimize = optimize,
    });
    daemon_tests_mod.addImport("zio", zio.module("zio"));
    daemon_tests_mod.addImport("websocket", websocket);
    daemon_tests_mod.addImport("wire", wire);
    const daemon_tests = b.addTest(.{
        .root_module = daemon_tests_mod,
    });
    const run_daemon_tests = b.addRunArtifact(daemon_tests);
    const test_daemon_step = b.step("test-daemon", "Run daemon tests");
    test_daemon_step.dependOn(&run_daemon_tests.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_sql_tests.step);
    test_step.dependOn(&run_sqlgen_tests.step);
    test_step.dependOn(&run_wire_tests.step);
    test_step.dependOn(&run_websocket_tests.step);
    test_step.dependOn(&run_layer_tests.step);
    test_step.dependOn(&run_daemon_tests.step);
    test_step.dependOn(&database_sqlgen_check.step);

    // Regenerate schema/wire.json in place from the Zig wire types.
    const write_schema = b.addUpdateSourceFiles();
    write_schema.addCopyFileToSource(run_gen_schema.captureStdOut(.{}), "schema/wire.json");
    const gen_schema_step = b.step("gen-schema", "Regenerate schema/wire.json from the wire types");
    gen_schema_step.dependOn(&write_schema.step);
}
