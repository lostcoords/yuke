package js

import "core:fmt"
import "core:nbio"
import "core:os"
import "core:strings"
import "core:testing"

import qjs "libs:bindings/quickjs"
import "libs:offload"
import "libs:testsupport"

@(private)
Fixture :: struct {
    loop: ^nbio.Event_Loop,
    pool: offload.Pool,
    exec: offload.Pool,
    host: Host,
    dir:  string,
}

// A host with all three shared modules, rooted at a fresh directory. `base` is that
// directory, so a test can use both a relative path and an absolute one.
@(private)
fixture_start :: proc(t: ^testing.T, f: ^Fixture, name: string) {
    tmp, has := os.lookup_env("TMPDIR", context.temp_allocator)
    if !has {
        tmp = "/tmp"
    }

    dir, join_err := os.join_path({tmp, name}, context.temp_allocator)
    testing.expect(t, join_err == nil, "the fixture path joins")
    os.remove_all(dir)
    testing.expect_value(t, os.make_directory_all(dir), nil)

    f.dir = dir
    f.loop = nbio.current_thread_event_loop()
    testing.expect_value(t, offload.pool_init(&f.pool, f.loop, 2), offload.Error.None)
    testing.expect_value(t, offload.pool_init(&f.exec, f.loop, 2), offload.Error.None)

    modules := [3]Module{fs_module(), exec_module(), diff_module()}
    testing.expect_value(
        t,
        init(
            &f.host,
            {modules = modules[:], base = dir, pool = &f.pool, exec_pool = &f.exec, allocator = context.allocator},
        ),
        Error.None,
    )
}

@(private)
fixture_stop :: proc(t: ^testing.T, f: ^Fixture) {
    ops_close(&f.host)
    testing.expect_value(t, offload.pool_drain(&f.pool), nil)
    testing.expect_value(t, offload.pool_drain(&f.exec), nil)
    offload.pool_destroy(&f.pool)
    offload.pool_destroy(&f.exec)
    destroy(&f.host)
    os.remove_all(f.dir)
}

// Run `source` and settle whatever it started. The fixture directory is prepended as `root`,
// because `fmt` reads a `{` in the source as a verb and cannot interpolate it.
@(private)
module_run :: proc(t: ^testing.T, name: string, source: string) -> string {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    f: Fixture
    fixture_start(t, &f, name)
    defer fixture_stop(t, &f)

    module := strings.concatenate({fmt.tprintf("const root = %q\n", f.dir), source}, context.temp_allocator)
    testing.expect(t, eval_module(&f.host, "test.js", module, context.temp_allocator), "the module evaluates")
    testsupport.nbio_run_until(t, &f.host, proc(h: ^Host) -> bool {return h.pending == 0}, "host op")

    global := qjs.global_object(f.host.ctx)
    defer qjs.free_value(f.host.ctx, global)

    value := qjs.get_property(f.host.ctx, global, "result")
    defer qjs.free_value(f.host.ctx, value)

    text, ok := qjs.to_string(f.host.ctx, value)
    if !testing.expect(t, ok, "globalThis.result should be readable") {
        return ""
    }

    defer qjs.free_string(f.host.ctx, text)

    // The engine owns `text`; clone it out before the frame that borrows it ends.
    return strings.clone(text, context.temp_allocator)
}

// The write half end to end, plus the two facts a read-before-edit guard rests on: a hash
// answers for a file that exists, and null for one that does not.
@(test)
test_fs_writes_and_reports_a_file :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    source := `
        import * as fs from "yuke:fs"
        globalThis.result = "pending"
        const run = async () => {
            // Compared to null explicitly, because join renders null as an empty string.
            const missing = (await fs.hash(root + "/note.txt")) === null
            const written = await fs.writeFile(root + "/note.txt", "hello")
            const present = await fs.exists(root + "/note.txt")
            const digest = await fs.hash(root + "/note.txt")

            return [missing, written, present, digest].join(":")
        }
        run().then(v => { globalThis.result = v }, e => { globalThis.result = "rejected: " + e })
    `

    // sha256("hello"), so the digest is the file's content and not its name or its size.
    expected := "true:5:true:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    testing.expect_value(t, module_run(t, "js-fs-write", source), expected)
}

// A relative path resolves against the base, and the absolute form of the same path names
// the same file. That equivalence is what makes one rule usable in both embedders.
@(test)
test_fs_resolves_a_relative_path_against_the_base :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    source := `
        import * as fs from "yuke:fs"
        globalThis.result = "pending"
        fs.writeFile("deep/note.txt", "same file")
            .then(() => fs.readFile(root + "/deep/note.txt"))
            .then(v => { globalThis.result = v }, e => { globalThis.result = "rejected: " + e })
    `

    testing.expect_value(t, module_run(t, "js-fs-relative", source), "same file")
}

// The base is a default, not a fence. A path outside it resolves, because a caller that also
// has yuke:exec could reach the same file with a command.
@(test)
test_fs_reads_outside_the_base :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    source := `
        import * as fs from "yuke:fs"
        globalThis.result = "pending"
        fs.exists("/etc").then(v => { globalThis.result = "" + v }, e => { globalThis.result = "rejected" })
    `

    testing.expect_value(t, module_run(t, "js-fs-outside", source), "true")
}

// An edit names its target by content. One match replaces, more than one is refused unless
// the caller says it meant all of them, and none is a failure rather than a silent no-op.
@(test)
test_fs_edit_counts_matches_before_it_writes :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    source := `
        import * as fs from "yuke:fs"
        const path = root + "/note.txt"
        globalThis.result = "pending"
        const fail = p => p.then(() => "resolved", e => "rejected")
        const run = async () => {
            await fs.writeFile(path, "one two one")
            const absent = await fail(fs.edit(path, "three", "four"))
            const ambiguous = await fail(fs.edit(path, "one", "1"))
            const all = await fs.edit(path, "one", "1", true)
            const single = await fs.edit(path, "two", "2")

            return [absent, ambiguous, all, single].join(":")
        }
        run().then(v => { globalThis.result = v }, e => { globalThis.result = "threw: " + e })
    `

    testing.expect_value(t, module_run(t, "js-fs-edit", source), "rejected:rejected:2:1")
}

// A tool writing into a directory that does not exist yet is ordinary, so the parents are
// made rather than reported as a missing-path failure.
@(test)
test_fs_write_makes_parent_directories :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    source := `
        import * as fs from "yuke:fs"
        globalThis.result = "pending"
        fs.writeFile(root + "/deep/deeper/note.txt", "x")
            .then(() => fs.exists(root + "/deep/deeper/note.txt"))
            .then(v => { globalThis.result = "" + v }, e => { globalThis.result = "rejected: " + e })
    `

    testing.expect_value(t, module_run(t, "js-fs-parents", source), "true")
}

// A command that outruns its deadline is killed and says so, rather than holding a worker
// until the embedder stops.
// The deadline bounds the drain too: a command that prints without stopping never reaches
// end of file, so only the deadline ends it.
// Commands run on their own pool, so one that holds a worker for its whole deadline does not
// stop a file read from answering.
// Closing operations reaches a running command. Draining the pool joins its worker, so a
// shutdown would otherwise wait out the whole deadline.
@(test)
test_diff_module_reports_hunks :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    source := `
        import { diff } from "yuke:diff"
        globalThis.result = "pending"
        diff("a.txt", "one\ntwo\nthree\n", "one\n2\nthree\n").then(
            d => { globalThis.result = d.path + ":" + d.hunks.length + ":" + d.hunks[0].lines.join("|") },
            e => { globalThis.result = "rejected: " + e },
        )
    `

    testing.expect_value(t, module_run(t, "js-diff", source), "a.txt:1: one|-two|+2| three")
}

// Without a base a relative path has no meaning, so it is refused at the call rather than
// resolved against whatever directory the process happens to be in.
@(test)
test_fs_without_a_base_refuses_a_relative_path :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    loop := nbio.current_thread_event_loop()

    pool: offload.Pool
    testing.expect_value(t, offload.pool_init(&pool, loop, 1), offload.Error.None)

    modules := [1]Module{fs_module()}

    h: Host
    testing.expect_value(t, init(&h, {modules = modules[:], pool = &pool, allocator = context.allocator}), Error.None)

    source := `
        import * as fs from "yuke:fs"
        globalThis.result = "pending"
        try {
            fs.readFile("note.txt")
            globalThis.result = "accepted"
        } catch (e) {
            globalThis.result = "threw"
        }
        fs.exists("/etc").then(v => { globalThis.result += ":" + v })
    `
    testing.expect(t, eval_module(&h, "test.js", source, context.temp_allocator), "the module evaluates")
    testsupport.nbio_run_until(t, &h, proc(h: ^Host) -> bool {return h.pending == 0}, "host op")

    global := qjs.global_object(h.ctx)
    value := qjs.get_property(h.ctx, global, "result")
    text, ok := qjs.to_string(h.ctx, value)
    testing.expect(t, ok, "globalThis.result should be readable")
    testing.expect_value(t, string(text), "threw:true")

    qjs.free_string(h.ctx, text)
    qjs.free_value(h.ctx, value)
    qjs.free_value(h.ctx, global)

    testing.expect_value(t, offload.pool_drain(&pool), nil)
    offload.pool_destroy(&pool)
    destroy(&h)
}
