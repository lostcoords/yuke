const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const host = b.graph.host;

    const zqlite = b.dependency("zqlite", .{ .target = target, .optimize = optimize });
    const zqlite_host = b.dependency("zqlite", .{ .target = host, .optimize = optimize });
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
    const quickjs = b.dependency("quickjs", .{ .target = target, .optimize = optimize });

    const sql = b.addModule("sql", .{
        .root_source_file = b.path("lib/sql/sql.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zqlite", .module = zqlite.module("zqlite") },
        },
    });
    const run_sql_tests = addTestRun(b, "sql", "Run SQL module tests", sql);

    const sqlgen = b.createModule(.{
        .root_source_file = b.path("tools/sqlgen/sqlgen.zig"),
        .target = host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zqlite", .module = zqlite_host.module("zqlite") },
        },
    });
    const run_sqlgen_tests = addTestRun(b, "sqlgen", "Run SQL generator tests", sqlgen);

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

    const wire = b.addModule("wire", .{
        .root_source_file = b.path("lib/wire/wire.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_wire_tests = addTestRun(b, "wire", "Run wire module tests", wire);

    const diff = b.addModule("diff", .{
        .root_source_file = b.path("lib/diff/diff.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_diff_tests = addTestRun(b, "diff", "Run diff module tests", diff);

    const websocket = b.addModule("websocket", .{
        .root_source_file = b.path("lib/websocket/websocket.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_websocket_tests = addTestRun(b, "websocket", "Run websocket module tests", websocket);

    const term = b.addModule("term", .{
        .root_source_file = b.path("lib/term/term.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "uucode", .module = uucode.module("uucode") },
            .{ .name = "zio", .module = zio.module("zio") },
        },
    });
    const run_term_tests = addTestRun(b, "term", "Run term module tests", term);

    const js_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/host.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "quickjs", .module = quickjs.module("quickjs") },
            .{ .name = "zio", .module = zio.module("zio") },
            .{ .name = "term", .module = term },
        },
    });
    const run_js_tests = addTestRun(b, "js", "Run JS host tests", js_mod);

    const tests = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wire", .module = wire },
            .{ .name = "sql", .module = sql },
            .{ .name = "zqlite", .module = zqlite.module("zqlite") },
            .{ .name = "zio", .module = zio.module("zio") },
            .{ .name = "websocket", .module = websocket },
        },
    });
    const run_layer_tests = b.addRunArtifact(b.addTest(.{
        .name = "src",
        .root_module = tests,
    }));

    // Fail the build if the committed queries drift from the SQL sources.
    const database_sqlgen_check = b.addRunArtifact(sqlgen_exe);
    database_sqlgen_check.addArg("--check");
    database_sqlgen_check.addArg("--migrations");
    addSqlDir(b, database_sqlgen_check, "src/database/migrations");
    database_sqlgen_check.addArg("--queries");
    addSqlDir(b, database_sqlgen_check, "src/database/queries");
    database_sqlgen_check.addArg("--queries-out");
    database_sqlgen_check.addFileArg(b.path("src/database/queries_gen.zig"));
    // Capture stdout so this Run has an output and can cache. File args hash the inputs.
    _ = database_sqlgen_check.captureStdOut(.{});

    const wire_host = b.createModule(.{
        .root_source_file = b.path("lib/wire/wire.zig"),
        .target = host,
        .optimize = optimize,
    });
    const gen_schema = b.addExecutable(.{
        .name = "gen-schema",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/wiregen/gen.zig"),
            .target = host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wire", .module = wire_host },
            },
        }),
    });
    const run_gen_schema = b.addRunArtifact(gen_schema);
    run_gen_schema.setCwd(b.path("."));

    const exe = b.addExecutable(.{
        .name = "yuke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zio", .module = zio.module("zio") },
                .{ .name = "websocket", .module = websocket },
                .{ .name = "wire", .module = wire },
                .{ .name = "sql", .module = sql },
                .{ .name = "zqlite", .module = zqlite.module("zqlite") },
                .{ .name = "term", .module = term },
                .{ .name = "quickjs", .module = quickjs.module("quickjs") },
            },
        }),
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    const run_step = b.step("run", "Run yuke (TUI by default)");
    run_step.dependOn(&run_exe.step);

    const run_daemon = b.addRunArtifact(exe);
    run_daemon.addArg("--daemon");
    if (b.args) |args| run_daemon.addArgs(args);
    const run_daemon_step = b.step("run-daemon", "Run the yuke daemon");
    run_daemon_step.dependOn(&run_daemon.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_sql_tests.step);
    test_step.dependOn(&run_sqlgen_tests.step);
    test_step.dependOn(&run_wire_tests.step);
    test_step.dependOn(&run_diff_tests.step);
    test_step.dependOn(&run_websocket_tests.step);
    test_step.dependOn(&run_term_tests.step);
    test_step.dependOn(&run_js_tests.step);
    test_step.dependOn(&run_layer_tests.step);
    test_step.dependOn(&database_sqlgen_check.step);

    const write_schema = b.addUpdateSourceFiles();
    write_schema.addCopyFileToSource(run_gen_schema.captureStdOut(.{}), "schema/wire.json");
    const gen_schema_step = b.step("gen-schema", "Regenerate schema/wire.json from the wire types");
    gen_schema_step.dependOn(&write_schema.step);
}

fn addTestRun(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    root_module: *std.Build.Module,
) *std.Build.Step.Run {
    const unit_tests = b.addTest(.{
        .name = name,
        .root_module = root_module,
    });
    const run = b.addRunArtifact(unit_tests);
    const step = b.step(b.fmt("test-{s}", .{name}), description);
    step.dependOn(&run.step);
    return run;
}

/// Pass `dir_path` as a directory argument and hash every `.sql` file inside it.
fn addSqlDir(b: *std.Build, run: *std.Build.Step.Run, dir_path: []const u8) void {
    run.addDirectoryArg(b.path(dir_path));
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.panic("open {s}: {s}", .{ dir_path, @errorName(err) });
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("iterate {s}: {s}", .{ dir_path, @errorName(err) })) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        run.addFileInput(b.path(b.fmt("{s}/{s}", .{ dir_path, entry.name })));
    }
}
