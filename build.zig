const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const host = b.graph.host;
    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const strip = b.option(bool, "strip", "Omit the debug info from the yuke binary");
    const test_filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};

    // A Debug test run spends most of its time in QuickJS and SQLite, so the C dependencies build optimized.
    const dep_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseSafe else optimize;
    const zqlite = b.dependency("zqlite", .{ .target = target, .optimize = dep_optimize });
    const zqlite_host = b.dependency("zqlite", .{ .target = host, .optimize = dep_optimize });
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });
    const uucode = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{
            "east_asian_width",
            "grapheme_break",
            "general_category",
            "is_emoji_presentation",
        }),
    });
    const quickjs = b.dependency("quickjs", .{ .target = target, .optimize = dep_optimize });
    const quickjs_c = quickjs.module("quickjs").import_table.get("c").?;
    const metrics = b.addOptions();
    metrics.addOption(bool, "enabled", b.option(bool, "metrics", "Enable allocation and UI work counters") orelse false);

    const sql = b.addModule("sql", .{
        .root_source_file = b.path("lib/sql/sql.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zqlite", .module = zqlite.module("zqlite") },
        },
    });
    const run_sql_tests = addTestRun(b, "sql", "Run SQL module tests", sql, test_filters);

    const sqlgen = b.createModule(.{
        .root_source_file = b.path("tools/sqlgen/sqlgen.zig"),
        .target = host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zqlite", .module = zqlite_host.module("zqlite") },
        },
    });
    const run_sqlgen_tests = addTestRun(b, "sqlgen", "Run SQL generator tests", sqlgen, test_filters);

    const sqlgen_exe = b.addExecutable(.{
        .name = "yuke-sqlgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sqlgen/main.zig"),
            .target = host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sqlgen", .module = sqlgen },
                .{ .name = "zqlite", .module = zqlite_host.module("zqlite") },
            },
        }),
    });
    const run_sqlgen = b.addRunArtifact(sqlgen_exe);
    if (b.args) |args| run_sqlgen.addArgs(args);
    const sqlgen_step = b.step("sqlgen", "Validate SQL and generate typed queries");
    sqlgen_step.dependOn(&run_sqlgen.step);

    const ai = b.addModule("ai", .{
        .root_source_file = b.path("lib/ai/ai.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_ai_tests = addTestRun(b, "ai", "Run AI module tests", ai, test_filters);

    // The vocabulary alone, so a missing or broken generated table cannot block a rebuild.
    const ai_vocab = b.createModule(.{
        .root_source_file = b.path("lib/ai/vocab.zig"),
        .target = host,
        .optimize = optimize,
    });
    const cataloggen = b.createModule(.{
        .root_source_file = b.path("tools/cataloggen/cataloggen.zig"),
        .target = host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_vocab", .module = ai_vocab },
        },
    });
    const run_cataloggen_tests = addTestRun(b, "cataloggen", "Run catalog generator tests", cataloggen, test_filters);

    const cataloggen_exe = b.addExecutable(.{
        .name = "yuke-cataloggen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/cataloggen/main.zig"),
            .target = host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cataloggen", .module = cataloggen },
            },
        }),
    });
    const run_cataloggen = b.addRunArtifact(cataloggen_exe);
    run_cataloggen.setCwd(b.path("."));
    // This run reads the control plane, so it must never answer from the build cache.
    run_cataloggen.has_side_effects = true;
    if (b.args) |args| run_cataloggen.addArgs(args);
    const cataloggen_step = b.step("cataloggen", "Fetch the provider catalog and bake it into the AI module");
    cataloggen_step.dependOn(&run_cataloggen.step);

    const proto = b.addModule("proto", .{
        .root_source_file = b.path("lib/proto/proto.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_proto_tests = addTestRun(b, "proto", "Run proto module tests", proto, test_filters);

    const term = b.addModule("term", .{
        .root_source_file = b.path("lib/term/term.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "uucode", .module = uucode.module("uucode") },
            .{ .name = "zio", .module = zio.module("zio") },
        },
    });
    const run_term_tests = addTestRun(b, "term", "Run term module tests", term, test_filters);

    // The exec tool binds libc posix_spawn through this module. translate-c gives each libc its own struct layout.
    const spawn_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c/spawn.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const app_imports: []const std.Build.Module.Import = &.{
        .{ .name = "quickjs", .module = quickjs.module("quickjs") },
        .{ .name = "quickjs_c", .module = quickjs_c },
        .{ .name = "spawn_c", .module = spawn_c.createModule() },
        .{ .name = "metrics", .module = metrics.createModule() },
        .{ .name = "term", .module = term },
        .{ .name = "proto", .module = proto },
        .{ .name = "sql", .module = sql },
        .{ .name = "zqlite", .module = zqlite.module("zqlite") },
        .{ .name = "zio", .module = zio.module("zio") },
        .{ .name = "ai", .module = ai },
    };

    const tests = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = app_imports,
    });
    const run_layer_tests = addTestRun(b, "src", "Run process and JavaScript host tests", tests, test_filters);
    b.step("test-js", "Run process and JavaScript host tests").dependOn(&run_layer_tests.step);

    // Fail the build if the committed queries drift from the SQL sources.
    const database_sqlgen_check = b.addRunArtifact(sqlgen_exe);
    database_sqlgen_check.addArg("--check");
    database_sqlgen_check.addArg("--migrations");
    addSqlDir(b, database_sqlgen_check, "src/store/migrations");
    database_sqlgen_check.addArg("--queries");
    addSqlDir(b, database_sqlgen_check, "src/store/queries");
    database_sqlgen_check.addArg("--queries-out");
    database_sqlgen_check.addFileArg(b.path("src/store/queries_gen.zig"));
    // Capture stdout so this Run has an output and can cache. File args hash the inputs.
    _ = database_sqlgen_check.captureStdOut(.{});

    const proto_host = b.createModule(.{
        .root_source_file = b.path("lib/proto/proto.zig"),
        .target = host,
        .optimize = optimize,
    });
    const gen_schema = b.addExecutable(.{
        .name = "gen-schema",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/protogen/gen.zig"),
            .target = host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_host },
            },
        }),
    });
    const run_gen_schema = b.addRunArtifact(gen_schema);
    run_gen_schema.setCwd(b.path("."));
    addSourceInputs(b, run_gen_schema, "lib/proto", ".zig");
    const schema_output = run_gen_schema.captureStdOut(.{});
    const dts_module = b.createModule(.{
        .root_source_file = b.path("tools/protogen/dts.zig"),
        .target = host,
        .optimize = optimize,
    });
    const gen_dts = b.addExecutable(.{ .name = "gen-proto-dts", .root_module = dts_module });
    const run_gen_dts = b.addRunArtifact(gen_dts);
    run_gen_dts.addFileArg(schema_output);
    const dts_output = run_gen_dts.captureStdOut(.{});
    const generator_tests = b.step("test-protogen", "Test the protocol generators");
    generator_tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = dts_module })).step);
    generator_tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = gen_schema.root_module })).step);

    const exe = b.addExecutable(.{
        .name = "yuke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = app_imports,
        }),
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    const run_step = b.step("run", "Run yuke (TUI by default)");
    run_step.dependOn(&run_exe.step);

    const bench_exe = b.addExecutable(.{
        .name = "yuke-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = app_imports,
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the benchmark (use -Doptimize=ReleaseFast)");
    bench_step.dependOn(&run_bench.step);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_sql_tests.step);
    test_step.dependOn(&run_sqlgen_tests.step);
    test_step.dependOn(&run_cataloggen_tests.step);
    test_step.dependOn(&run_proto_tests.step);
    test_step.dependOn(&run_ai_tests.step);
    test_step.dependOn(&run_term_tests.step);
    test_step.dependOn(&run_layer_tests.step);
    test_step.dependOn(&database_sqlgen_check.step);
    test_step.dependOn(generator_tests);

    const check_schema = b.step("check-schema", "Check the generated protocol files without edits");
    check_schema.dependOn(&b.addCheckFile(schema_output, .{ .expected_exact = @embedFile("schema/proto.json") }).step);
    check_schema.dependOn(&b.addCheckFile(dts_output, .{ .expected_exact = @embedFile("src/js/app/generated/proto.d.ts") }).step);
    test_step.dependOn(check_schema);

    const write_schema = b.addUpdateSourceFiles();
    write_schema.addCopyFileToSource(schema_output, "schema/proto.json");
    write_schema.addCopyFileToSource(dts_output, "src/js/app/generated/proto.d.ts");
    const gen_schema_step = b.step("gen-schema", "Regenerate the JSON schema and TypeScript declarations");
    gen_schema_step.dependOn(&write_schema.step);
}

fn addTestRun(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    root_module: *std.Build.Module,
    filters: []const []const u8,
) *std.Build.Step.Run {
    const unit_tests = b.addTest(.{
        .name = name,
        .root_module = root_module,
        .filters = filters,
    });
    const run = b.addRunArtifact(unit_tests);
    const step = b.step(b.fmt("test-{s}", .{name}), description);
    step.dependOn(&run.step);
    return run;
}

/// Pass `dir_path` as a directory argument and hash every `.sql` file inside it.
fn addSqlDir(b: *std.Build, run: *std.Build.Step.Run, dir_path: []const u8) void {
    run.addDirectoryArg(b.path(dir_path));
    addSourceInputs(b, run, dir_path, ".sql");
}

fn addSourceInputs(b: *std.Build, run: *std.Build.Step.Run, dir_path: []const u8, suffix: []const u8) void {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.panic("open {s}: {s}", .{ dir_path, @errorName(err) });
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("iterate {s}: {s}", .{ dir_path, @errorName(err) })) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        run.addFileInput(b.path(b.fmt("{s}/{s}", .{ dir_path, entry.name })));
    }
}
