package js

import "base:runtime"
import "core:c"
import "core:nbio"
import "core:os"
import "core:strings"
import "core:testing"

import qjs "libs:bindings/quickjs"
import "libs:offload"
import "libs:testsupport"

// Embedder state these tests hang off the host, so a module callback reading it proves the
// host reached the right embedder rather than a global.
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

// A module only these tests install, covering the registry any embedder composes.
@(private = "file")
probe_module_init :: proc "c" (ctx: ^qjs.Context, m: ^qjs.Module_Def) -> c.int {
    context = runtime.default_context()

    tag := "none"
    if p := (^Probe)(user_of(ctx)); p != nil {
        tag = p.tag
    }

    obj := qjs.new_object(ctx)
    _ = qjs.set_property(ctx, obj, "tag", qjs.new_string(ctx, tag))

    if !qjs.set_module_export(ctx, m, "probe", obj) {
        return -1
    }

    return 0
}

@(private = "file")
probe_report :: proc(user: rawptr, source: string, text: string) {
    p := (^Probe)(user)
    append(&p.reports, strings.concatenate({source, ": ", text}, context.temp_allocator))
}

// Scripts report through `globalThis.result`; a promise's value is not otherwise reachable
// from Odin.
@(private = "file")
result_of :: proc(t: ^testing.T, h: ^Host) -> string {
    global := qjs.global_object(h.ctx)
    defer qjs.free_value(h.ctx, global)

    value := qjs.get_property(h.ctx, global, "result")
    defer qjs.free_value(h.ctx, value)

    text, ok := qjs.to_string(h.ctx, value)
    if !testing.expect(t, ok, "globalThis.result should be readable") {
        return ""
    }

    defer qjs.free_string(h.ctx, text)

    // The engine owns `text`; clone it out before the frame that borrows it ends.
    return strings.clone(text, context.temp_allocator)
}

// An embedder's own module resolves through the shared loader, and its callback reaches
// that embedder's state.
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

// Two hosts at once, each reaching its own embedder. The daemon's tests run one host at a
// time; this is what says the design carries no global.
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

// Nothing is installed behind the caller's back: a module it did not list is absent, and
// the message names the specifier.
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
        !eval_module(&h, "fs.js", `import { fs } from "yuke:fs"`, context.temp_allocator),
        "yuke:fs should be unavailable",
    )

    if testing.expect(t, len(probe.reports) == 1, "the failure should be reported once") {
        testing.expect(t, strings.contains(probe.reports[0], "yuke:fs"), probe.reports[0])
    }
}

// The module set is closed: an unknown specifier is a script error, never a lookup on disk.
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

// A module whose top level throws rejects the promise `eval` returns rather than raising
// out of it. Reporting success there would call a script that threw a success.
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

    if testing.expect(t, len(probe.reports) == 1, "the rejection should be reported once") {
        testing.expect(t, strings.contains(probe.reports[0], "boom"), probe.reports[0])
    }
}

// A syntax error is the one failure `eval` does raise directly, and it must be reported the
// same way a rejection is.
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

// `call` is the seam an embedder drives its own callbacks through, so a throwing callback
// reports and reports as failed rather than handing back an exception value.
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

    if testing.expect(t, len(probe.reports) == 1, "the throw should be reported once") {
        testing.expect(t, strings.contains(probe.reports[0], "from a callback"), probe.reports[0])
    }
}

// The client's configuration: an embedder module and the built-in one installed together.
// Neither hides the other, and a host op still settles.
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
                root = root,
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
        import { fs } from "yuke:fs"
        globalThis.result = "pending"
        fs.readDir(".").then(
            entries => { globalThis.result = probe.tag + ":" + (entries.length > 0) },
            err => { globalThis.result = "rejected: " + err },
        )
    `
    testing.expect(t, eval_module(&h, "both.js", source, context.temp_allocator), "both modules resolve")

    testsupport.nbio_run_until(t, &h, proc(h: ^Host) -> bool {return h.pending == 0}, "yuke:fs host op")

    testing.expect_value(t, result_of(t, &h), "client:true")

    // The ordering every embedder owes this host: drain, then release.
    testing.expect_value(t, offload.pool_drain(&pool), nil)
    offload.pool_destroy(&pool)
    destroy(&h)
}

// Listing `yuke:fs` without a root installs a module that refuses every call: the import
// resolves, and the throw arrives where the script asks for a path.
@(test)
test_listed_fs_without_a_root_refuses_calls :: proc(t: ^testing.T) {
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
        import { fs } from "yuke:fs"
        globalThis.result = "imported"
        try { fs.readFile("x") } catch (e) { globalThis.result = "threw" }
    `
    testing.expect(t, eval_module(&h, "fs.js", source, context.temp_allocator), "the import resolves")
    testing.expect_value(t, result_of(t, &h), "threw")
}

// A caller's list is copied, so composing it from a temporary is safe — which is how both
// embedders build theirs.
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

    // Resolved after the caller's slice went out of scope.
    source := `import { probe } from "test:probe"; globalThis.result = probe.tag`
    testing.expect(t, eval_module(&h, "probe.js", source, context.temp_allocator), "the module resolves")
    testing.expect_value(t, result_of(t, &h), "copied")
}
