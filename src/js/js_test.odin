package js

import "base:runtime"
import "core:c"
import "core:mem"
import "core:nbio"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import qjs "libs:bindings/quickjs"
import "libs:offload"
import "libs:testsupport"

// Embedder state hung off the host so a module callback proves the right embedder was reached.
@(private = "file")
Probe :: struct {
    tag:     string,
    reports: [dynamic]string,
}

@(private = "file")
PROBE_MODULE :: "test:probe"

@(private = "file")
PROBE_EXPORTS := []string{"probe"}

@(private = "file")
PROBE_MODULES := []Module{{name = PROBE_MODULE, init = probe_module_init, exports = PROBE_EXPORTS}}

@(private = "file")
probe_module_init :: proc "c" (ctx: ^qjs.Context, m: ^qjs.Module_Def) -> c.int {
    context = runtime.default_context()

    tag := "none"
    if p := (^Probe)(user_of(ctx)); p != nil do tag = p.tag

    obj := qjs.new_object(ctx)
    _ = qjs.set_property(ctx, obj, "tag", qjs.new_string(ctx, tag))

    if !qjs.set_module_export(ctx, m, "probe", obj) do return -1

    return 0
}

@(private = "file")
probe_report :: proc(user: rawptr, source: string, text: string) {
    p := (^Probe)(user)
    append(&p.reports, strings.concatenate({source, ": ", text}, context.temp_allocator))
}

// Scripts report through `globalThis.result`; a promise value is not otherwise reachable from Odin.
@(private = "file")
result_of :: proc(t: ^testing.T, h: ^Host) -> string {
    global := qjs.global_object(h.ctx)
    defer qjs.free_value(h.ctx, global)

    value := qjs.get_property(h.ctx, global, "result")
    defer qjs.free_value(h.ctx, value)

    text, ok := qjs.to_string(h.ctx, value)
    if !testing.expect(t, ok, "globalThis.result should be readable") do return ""

    defer qjs.free_string(h.ctx, text)

    // Engine owns `text`; clone out before the borrow ends.
    return strings.clone(text, context.temp_allocator)
}

@(test)
test_embedder_module_resolves_with_its_own_state :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    probe := Probe {
        tag = "alpha",
    }
    defer delete(probe.reports)

    h: Host
    testing.expect_value(
        t,
        init(&h, {modules = PROBE_MODULES, user = &probe, allocator = context.allocator}),
        Error.None,
    )
    defer destroy(&h)

    source := `import { probe } from "test:probe"; globalThis.result = probe.tag`
    testing.expect(t, eval_module(&h, "probe.js", source, context.temp_allocator), "the probe module evaluates")
    testing.expect_value(t, result_of(t, &h), "alpha")
}

// Two hosts at once, each with its own embedder — no global host state.
@(test)
test_hosts_do_not_share_embedder_state :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    first := Probe {
        tag = "first",
    }
    second := Probe {
        tag = "second",
    }
    defer delete(first.reports)
    defer delete(second.reports)

    a: Host
    b: Host
    testing.expect_value(
        t,
        init(&a, {modules = PROBE_MODULES, user = &first, allocator = context.allocator}),
        Error.None,
    )
    defer destroy(&a)
    testing.expect_value(
        t,
        init(&b, {modules = PROBE_MODULES, user = &second, allocator = context.allocator}),
        Error.None,
    )
    defer destroy(&b)

    source := `import { probe } from "test:probe"; globalThis.result = probe.tag`
    testing.expect(t, eval_module(&a, "probe.js", source, context.temp_allocator), "the first host evaluates")
    testing.expect(t, eval_module(&b, "probe.js", source, context.temp_allocator), "the second host evaluates")

    testing.expect_value(t, result_of(t, &a), "first")
    testing.expect_value(t, result_of(t, &b), "second")
}

@(test)
test_an_unlisted_module_is_not_installed :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    probe: Probe
    defer delete(probe.reports)

    h: Host
    testing.expect_value(
        t,
        init(&h, {user = &probe, report = probe_report, allocator = context.allocator}),
        Error.None,
    )
    defer destroy(&h)

    testing.expect(
        t,
        !eval_module(&h, "fs.js", `import * as fs from "yuke:fs"`, context.temp_allocator),
        "yuke:fs should be unavailable",
    )

    if testing.expect(t, len(probe.reports) == 1, "the failure should be reported once") do testing.expect(t, strings.contains(probe.reports[0], "yuke:fs"), probe.reports[0])
}

// Closed module set: unknown specifier is a script error, never a disk lookup.
@(test)
test_unknown_module_is_refused :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    probe: Probe
    defer delete(probe.reports)

    h: Host
    testing.expect_value(
        t,
        init(&h, {user = &probe, report = probe_report, allocator = context.allocator}),
        Error.None,
    )
    defer destroy(&h)

    testing.expect(
        t,
        !eval_module(&h, "nope.js", `import "does:not:exist"`, context.temp_allocator),
        "an unknown module should fail to evaluate",
    )
    testing.expect(t, len(probe.reports) == 1, "the failure should be reported once")
}

// TLA of an already-settled promise finishes in the first microtask drain.
@(test)
test_top_level_await_resolved_promise :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    testing.expect_value(t, init(&h, {allocator = context.allocator}), Error.None)
    defer destroy(&h)

    source := `
        const v = await Promise.resolve("ready")
        globalThis.result = v
    `
    testing.expect(
        t,
        eval_module(&h, "tla-resolved.js", source, context.temp_allocator),
        "top-level await of a resolved promise should finish",
    )
    testing.expect_value(t, result_of(t, &h), "ready")
}

// Never-settling TLA with no host op must fail so a suspended module is not treated as loaded.
// Hang path fails immediately (pending == 0), not by burning the deadline.
@(test)
test_top_level_await_never_settling_fails :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    probe: Probe
    defer delete(probe.reports)

    h: Host
    testing.expect_value(
        t,
        init(&h, {user = &probe, report = probe_report, deadline = 5 * time.Second, allocator = context.allocator}),
        Error.None,
    )
    defer destroy(&h)

    started := time.tick_now()
    source := `await new Promise(() => {})`
    testing.expect(
        t,
        !eval_module(&h, "tla-hang.js", source, context.temp_allocator),
        "a never-settling top-level await should fail evaluation",
    )
    elapsed := time.tick_diff(started, time.tick_now())
    testing.expect(t, elapsed < 500 * time.Millisecond, "hang path must not wait out the full deadline")
    if testing.expect(t, len(probe.reports) >= 1, "the unfinished module should be reported") do testing.expect(t, strings.contains(probe.reports[0], "did not finish evaluating"), probe.reports[0])
}

// Rejected host op under TLA rejects the module (eval_module returns false).
@(test)
test_top_level_await_fs_rejection :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    pool: offload.Pool
    testing.expect_value(t, offload.pool_init(&pool, loop, 1), offload.Error.None)

    base, has := os.lookup_env("TMPDIR", context.temp_allocator)
    if !has do base = "/tmp"
    dir, join_err := os.join_path({base, "yuke-js-tla-reject"}, context.temp_allocator)
    testing.expect(t, join_err == nil, "temp root path joins")
    os.remove_all(dir)
    testing.expect_value(t, os.make_directory_all(dir), nil)
    defer os.remove_all(dir)

    probe: Probe
    defer delete(probe.reports)

    modules := [1]Module{fs_module()}
    h: Host
    testing.expect_value(
        t,
        init(
            &h,
            {
                modules = modules[:],
                base = dir,
                pool = &pool,
                user = &probe,
                report = probe_report,
                allocator = context.allocator,
            },
        ),
        Error.None,
    )

    source := `
        import * as fs from "yuke:fs"
        await fs.readFile("missing.txt")
    `
    testing.expect(
        t,
        !eval_module(&h, "tla-reject.js", source, context.temp_allocator),
        "top-level await of a rejected host op should fail evaluation",
    )
    testing.expect(t, h.pending == 0, "failed eval must idle host ops")
    testing.expect(t, h.ops_open, "ops must reopen after failed eval")

    testing.expect_value(t, offload.pool_drain(&pool), nil)
    offload.pool_destroy(&pool)
    destroy(&h)
}

// Multi-step TLA + expired deadline must not leave pending ops or assert on pool drain:
// abandoned continuations are refused via ops_open until in-flight work settles.
@(test)
test_top_level_await_deadline_abandons_without_pending :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    pool: offload.Pool
    testing.expect_value(t, offload.pool_init(&pool, loop, 1), offload.Error.None)

    base, has := os.lookup_env("TMPDIR", context.temp_allocator)
    if !has do base = "/tmp"
    dir, join_err := os.join_path({base, "yuke-js-tla-deadline"}, context.temp_allocator)
    testing.expect(t, join_err == nil, "temp root path joins")
    os.remove_all(dir)
    testing.expect_value(t, os.make_directory_all(dir), nil)
    defer os.remove_all(dir)

    names := [2]string{"a.txt", "b.txt"}
    for name in names {
        path, perr := os.join_path({dir, name}, context.temp_allocator)
        testing.expect(t, perr == nil, "fixture path joins")
        testing.expect_value(t, os.write_entire_file(path, transmute([]byte)string(name)), nil)
    }

    probe: Probe
    defer delete(probe.reports)

    modules := [1]Module{fs_module()}
    h: Host
    testing.expect_value(
        t,
        init(
            &h,
            {
                modules   = modules[:],
                base      = dir,
                pool      = &pool,
                user      = &probe,
                report    = probe_report,
                // Tight enough that multi-step TLA often abandons before both awaits finish.
                deadline  = 1 * time.Nanosecond,
                allocator = context.allocator,
            },
        ),
        Error.None,
    )

    source := `
        import * as fs from "yuke:fs"
        await fs.readFile("a.txt")
        await fs.readFile("b.txt")
        globalThis.result = "done"
    `
    // May succeed on a very fast machine if both awaits finish before the deadline check;
    // either way pending must be 0 and pool drain must not assert.
    _ = eval_module(&h, "tla-deadline.js", source, context.temp_allocator)
    testing.expect_value(t, h.pending, 0)
    testing.expect(t, h.ops_open, "ops must reopen after eval")

    testing.expect_value(t, offload.pool_drain(&pool), nil)
    offload.pool_destroy(&pool)
    destroy(&h)
}

// Top-level throw rejects the module promise rather than raising out of eval.
@(test)
test_top_level_throw_is_reported :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    probe: Probe
    defer delete(probe.reports)

    h: Host
    testing.expect_value(
        t,
        init(&h, {user = &probe, report = probe_report, allocator = context.allocator}),
        Error.None,
    )
    defer destroy(&h)

    testing.expect(
        t,
        !eval_module(&h, "throw.js", `throw new Error("boom")`, context.temp_allocator),
        "a top-level throw should fail evaluation",
    )

    if testing.expect(t, len(probe.reports) == 1, "the rejection should be reported once") do testing.expect(t, strings.contains(probe.reports[0], "boom"), probe.reports[0])
}

@(test)
test_syntax_error_is_reported :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    probe: Probe
    defer delete(probe.reports)

    h: Host
    testing.expect_value(
        t,
        init(&h, {user = &probe, report = probe_report, allocator = context.allocator}),
        Error.None,
    )
    defer destroy(&h)

    testing.expect(
        t,
        !eval_module(&h, "bad.js", `function (`, context.temp_allocator),
        "a syntax error should fail evaluation",
    )
    testing.expect(t, len(probe.reports) == 1, "the syntax error should be reported once")
}

@(test)
test_call_reports_a_throwing_callback :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    probe: Probe
    defer delete(probe.reports)

    h: Host
    testing.expect_value(
        t,
        init(&h, {user = &probe, report = probe_report, allocator = context.allocator}),
        Error.None,
    )
    defer destroy(&h)

    source := `globalThis.boom = () => { throw new Error("from a callback") }`
    testing.expect(t, eval_module(&h, "call.js", source, context.temp_allocator), "the module evaluates")

    global := qjs.global_object(h.ctx)
    defer qjs.free_value(h.ctx, global)

    fn := qjs.get_property(h.ctx, global, "boom")
    defer qjs.free_value(h.ctx, fn)

    _, ok := call(&h, fn, qjs.undefined(), nil, "boom")
    testing.expect(t, !ok, "a throwing callback should report failure")

    if testing.expect(t, len(probe.reports) == 1, "the throw should be reported once") do testing.expect(t, strings.contains(probe.reports[0], "from a callback"), probe.reports[0])
}

@(test)
test_embedder_module_and_fs_coexist :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    pool: offload.Pool
    testing.expect_value(t, offload.pool_init(&pool, loop, 1), offload.Error.None)

    root, root_err := os.get_working_directory(context.temp_allocator)
    testing.expect(t, root_err == nil, "the working directory resolves")

    probe := Probe {
        tag = "client",
    }
    defer delete(probe.reports)

    modules := [2]Module{PROBE_MODULES[0], fs_module()}

    h: Host
    testing.expect_value(
        t,
        init(
            &h,
            {
                modules = modules[:],
                base = root,
                pool = &pool,
                user = &probe,
                report = probe_report,
                allocator = context.allocator,
            },
        ),
        Error.None,
    )

    source := `
        import { probe } from "test:probe"
        import * as fs from "yuke:fs"
        globalThis.result = "pending"
        fs.readDir(".").then(
            entries => { globalThis.result = probe.tag + ":" + (entries.length > 0) },
            err => { globalThis.result = "rejected: " + err },
        )
    `
    testing.expect(t, eval_module(&h, "both.js", source, context.temp_allocator), "both modules resolve")

    testsupport.nbio_run_until(t, &h, proc(h: ^Host) -> bool {return h.pending == 0}, "yuke:fs host op")

    testing.expect_value(t, result_of(t, &h), "client:true")

    // Drain, then release — ordering every embedder owes this host.
    testing.expect_value(t, offload.pool_drain(&pool), nil)
    offload.pool_destroy(&pool)
    destroy(&h)
}

// TLA of a host op: eval_module pumps until the body finishes (not left suspended).
@(test)
test_top_level_await_fs_read_file :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    pool: offload.Pool
    testing.expect_value(t, offload.pool_init(&pool, loop, 1), offload.Error.None)

    base, has := os.lookup_env("TMPDIR", context.temp_allocator)
    if !has do base = "/tmp"
    dir, join_err := os.join_path({base, "yuke-js-tla-fs"}, context.temp_allocator)
    testing.expect(t, join_err == nil, "temp root path joins")
    os.remove_all(dir)
    testing.expect_value(t, os.make_directory_all(dir), nil)
    defer os.remove_all(dir)

    path, path_err := os.join_path({dir, "note.txt"}, context.temp_allocator)
    testing.expect(t, path_err == nil, "fixture path joins")
    testing.expect_value(t, os.write_entire_file(path, transmute([]byte)string("from tla")), nil)

    modules := [1]Module{fs_module()}

    h: Host
    testing.expect_value(
        t,
        init(&h, {modules = modules[:], base = dir, pool = &pool, allocator = context.allocator}),
        Error.None,
    )

    source := `
        import * as fs from "yuke:fs"
        const text = await fs.readFile("note.txt")
        globalThis.result = text
    `
    testing.expect(
        t,
        eval_module(&h, "tla-fs.js", source, context.temp_allocator),
        "top-level await of yuke:fs should finish during eval_module",
    )
    testing.expect_value(t, result_of(t, &h), "from tla")
    testing.expect_value(t, h.pending, 0)

    testing.expect_value(t, offload.pool_drain(&pool), nil)
    offload.pool_destroy(&pool)
    destroy(&h)
}

// Every path op offloads, so listing yuke:fs without a pool installs a module that refuses
// every call rather than one that blocks the loop thread.
@(test)
test_listed_fs_without_a_pool_refuses_calls :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    probe: Probe
    defer delete(probe.reports)

    modules := [1]Module{fs_module()}

    h: Host
    testing.expect_value(
        t,
        init(&h, {modules = modules[:], user = &probe, report = probe_report, allocator = context.allocator}),
        Error.None,
    )
    defer destroy(&h)

    source := `
        import * as fs from "yuke:fs"
        globalThis.result = "imported"
        try { fs.readFile("x") } catch (e) { globalThis.result = "threw" }
    `
    testing.expect(t, eval_module(&h, "fs.js", source, context.temp_allocator), "the import resolves")
    testing.expect_value(t, result_of(t, &h), "threw")
}

// Caller's module list is copied, so composing from a temporary is safe.
@(test)
test_module_list_may_be_a_temporary :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    probe := Probe {
        tag = "copied",
    }
    defer delete(probe.reports)

    h: Host

    {
        modules := [1]Module{PROBE_MODULES[0]}
        testing.expect_value(
            t,
            init(&h, {modules = modules[:], user = &probe, report = probe_report, allocator = context.allocator}),
            Error.None,
        )
    }

    defer destroy(&h)

    source := `import { probe } from "test:probe"; globalThis.result = probe.tag`
    testing.expect(t, eval_module(&h, "probe.js", source, context.temp_allocator), "the module resolves")
    testing.expect_value(t, result_of(t, &h), "copied")
}

// Two ES modules via the resolve seam — loader compiles embedder source, not just native modules.
@(private = "file")
RESOLVED_A :: `import { b } from "test:resolved-b"; export const a = "A+" + b`

@(private = "file")
RESOLVED_B :: `export const b = "B"`

@(private = "file")
probe_resolve :: proc(user: rawptr, name: string, allocator: mem.Allocator) -> (string, bool, bool) {
    switch name {
    case "test:resolved-a":
        return RESOLVED_A, false, true

    case "test:resolved-b":
        return RESOLVED_B, false, true

    case "test:owned":
        // Host allocator; loader owns the free. A leak fails the memory tracker.
        source, _ := strings.clone(`export const v = "owned"`, allocator)
        return source, true, true
    }

    return "", false, false
}

@(test)
test_resolved_source_module_imports_another :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    probe := Probe {
        tag = "resolve",
    }
    defer delete(probe.reports)

    h: Host
    testing.expect_value(
        t,
        init(&h, {user = &probe, report = probe_report, resolve = probe_resolve, allocator = context.allocator}),
        Error.None,
    )
    defer destroy(&h)

    source := `import { a } from "test:resolved-a"; globalThis.result = a`
    testing.expect(t, eval_module(&h, "resolve.js", source, context.temp_allocator), "the resolved chain evaluates")
    testing.expect_value(t, result_of(t, &h), "A+B")
}

// Owned resolved source is freed by the loader after compile (memory tracker).
@(test)
test_owned_resolved_source_is_freed :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    probe := Probe {
        tag = "owned",
    }
    defer delete(probe.reports)

    h: Host
    testing.expect_value(
        t,
        init(&h, {user = &probe, report = probe_report, resolve = probe_resolve, allocator = context.allocator}),
        Error.None,
    )
    defer destroy(&h)

    source := `import { v } from "test:owned"; globalThis.result = v`
    testing.expect(t, eval_module(&h, "owned.js", source, context.temp_allocator), "the owned module evaluates")
    testing.expect_value(t, result_of(t, &h), "owned")
}

// Declining resolver leaves the loader closed: import throws as with no resolver.
@(test)
test_resolver_declining_still_throws :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    probe := Probe {
        tag = "decline",
    }
    defer delete(probe.reports)

    h: Host
    testing.expect_value(
        t,
        init(&h, {user = &probe, report = probe_report, resolve = probe_resolve, allocator = context.allocator}),
        Error.None,
    )
    defer destroy(&h)

    testing.expect(
        t,
        !eval_module(&h, "nope.js", `import "test:absent"`, context.temp_allocator),
        "an unresolved specifier fails to evaluate",
    )
    testing.expect(t, len(probe.reports) > 0, "the failure is reported")
}
