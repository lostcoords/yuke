const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zqlite = b.dependency("zqlite", .{
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

    // The domain package: the shared session-projection fold. Imports wire.
    const domain = b.addModule("domain", .{
        .root_source_file = b.path("src/domain/domain.zig"),
        .target = target,
        .optimize = optimize,
    });
    domain.addImport("wire", wire);
    const domain_tests = b.addTest(.{
        .root_module = domain,
    });
    const run_domain_tests = b.addRunArtifact(domain_tests);

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

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_sql_tests.step);
    test_step.dependOn(&run_sqlgen_tests.step);
    test_step.dependOn(&run_wire_tests.step);
    test_step.dependOn(&run_domain_tests.step);

    // Regenerate schema/wire.json in place from the Zig wire types.
    const write_schema = b.addUpdateSourceFiles();
    write_schema.addCopyFileToSource(run_gen_schema.captureStdOut(.{}), "schema/wire.json");
    const gen_schema_step = b.step("gen-schema", "Regenerate schema/wire.json from the wire types");
    gen_schema_step.dependOn(&write_schema.step);
}
