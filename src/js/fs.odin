package js

import "base:runtime"
import "core:c"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import qjs "libs:bindings/quickjs"
import "libs:offload"

// Read-only filesystem access, rooted at `Host.root`. Installed for any embedder that
// supplies both a root and a pool; `yuke:term` and the rest stay embedder-specific.
FS_MODULE :: "yuke:fs"

// Declared up front because ES modules resolve bindings before any module body runs.
@(rodata)
FS_EXPORTS := []string{"fs"}

// `yuke:fs` for a caller's module list. Calls throw unless the host was given a root and a
// pool, so listing it without configuring one installs a module that refuses every request.
fs_module :: proc() -> Module {
    return {name = FS_MODULE, init = fs_module_init, exports = FS_EXPORTS}
}

// Largest file `readFile` will materialize. A host op holds its result in memory until the
// promise settles, so this bounds one script's reach into the runtime's allocation ceiling.
FS_MAX_FILE_BYTES :: 8 * mem.Megabyte

// Job arena block size and its out-of-band threshold, kept equal on purpose: a job larger
// than the block but under a bigger threshold would fit neither path and fail every mid-sized read.
FS_JOB_BLOCK_BYTES :: 2 * mem.Kilobyte

// Which `yuke:fs` call a job answers.
Fs_Op :: enum {
    Read_File,
    Stat,
    Read_Dir,
}

// Why a `yuke:fs` call could not be answered. Every one of these is peer-supplied input or
// an operating condition, so each becomes a rejected promise rather than an assertion.
Fs_Error :: enum {
    // The pass completed; the result fields are populated.
    None,

    // The path did not resolve, or resolved outside the configured root.
    Denied,

    // The path does not exist or could not be opened.
    Unreadable,

    // `readFile` found more bytes than it will materialize.
    Too_Large,
}

// One in-flight `yuke:fs` call, owned across the offloaded pass and freed by the completion.
// Its settle functions are owned `Value`s in a live context, so `Host.pending` counts these jobs.
Fs_Job :: struct {
    // Runs the filesystem pass off the reactor; carried inline so submitting never allocates.
    task:      offload.Task(Fs_Job),

    // Owning host, for the context the completion settles into.
    host:      ^Host,

    // Which call this answers.
    op:        Fs_Op,

    // Owned clone of the requested path, already joined to the root.
    path:      string,

    // Promise settle functions, owned until the completion calls and frees them.
    resolve:   qjs.Value,
    reject:    qjs.Value,

    // What the pass decided. Nil until the worker finishes; `.None` is success.
    outcome:   Maybe(Fs_Error),

    // `readFile` contents.
    contents:  []byte,

    // `stat` findings.
    info:      os.File_Info,

    // `readDir` listing.
    entries:   []os.File_Info,

    // Backs every owned allocation above, from the process heap rather than the host's
    // allocator: the worker is this arena's only writer while the loop thread uses the host's.
    arena:     mem.Dynamic_Arena,
    allocator: mem.Allocator,
}

// Install the module's single export. Every function returns a promise: a synchronous host
// op would block the one runtime, and with it every other session.
fs_module_init :: proc "c" (ctx: ^qjs.Context, m: ^qjs.Module_Def) -> c.int {
    context = runtime.default_context()

    fs := qjs.new_object(ctx)
    _ = qjs.set_property(ctx, fs, "readFile", qjs.new_function(ctx, fs_read_file, "readFile", 1))
    _ = qjs.set_property(ctx, fs, "stat", qjs.new_function(ctx, fs_stat, "stat", 1))
    _ = qjs.set_property(ctx, fs, "readDir", qjs.new_function(ctx, fs_read_dir, "readDir", 1))

    if !qjs.set_module_export(ctx, m, "fs", fs) {
        return -1
    }

    return 0
}

@(private = "file")
fs_read_file :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    return fs_begin(ctx, .Read_File, argc, argv)
}

@(private = "file")
fs_stat :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()
    return fs_begin(ctx, .Stat, argc, argv)
}

@(private = "file")
fs_read_dir :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()

    return fs_begin(ctx, .Read_Dir, argc, argv)
}

// Turn one host call into a pending promise plus an offloaded pass. A bad argument throws
// synchronously (a script bug); a path that merely can't be read rejects instead.
@(private = "file")
fs_begin :: proc(ctx: ^qjs.Context, op: Fs_Op, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    h := (^Host)(qjs.get_context_opaque(ctx))

    if h == nil || h.root == "" {
        return qjs.throw_type_error(ctx, "yuke:fs needs a configured js root")
    }

    if argc < 1 || !qjs.is_string(argv[0]) {
        return qjs.throw_type_error(ctx, "yuke:fs expects a path string")
    }

    requested, got := qjs.to_string(ctx, argv[0])
    if !got {
        return qjs.throw_type_error(ctx, "yuke:fs could not read its path argument")
    }

    defer qjs.free_string(ctx, requested)

    assert(h.pool != nil, "an installed fs module always has a pool")

    job, aerr := new(Fs_Job, h.allocator)
    if aerr != nil {
        return qjs.throw_type_error(ctx, "out of memory")
    }

    job^ = {}
    job.host = h
    job.op = op
    mem.dynamic_arena_init(
        &job.arena,
        runtime.heap_allocator(),
        runtime.heap_allocator(),
        FS_JOB_BLOCK_BYTES,
        FS_JOB_BLOCK_BYTES,
    )
    job.allocator = mem.dynamic_arena_allocator(&job.arena)

    // Joined here so the pass receives one concrete path. `filepath.join` keeps even an
    // absolute argument under the root, leaving the containment check below as the only escape hatch.
    joined, join_err := filepath.join({h.root, requested}, job.allocator)

    if join_err != nil {
        fs_job_free(job)
        return qjs.throw_type_error(ctx, "out of memory")
    }

    job.path = joined

    promise, resolve, reject := qjs.new_promise(ctx)
    if qjs.is_exception(promise) {
        fs_job_free(job)
        return promise
    }

    job.resolve = resolve
    job.reject = reject
    h.pending += 1

    offload.submit(h.pool, job, fs_job_run, fs_job_done)

    return promise
}

// Worker thread; touches only `job`, never the context, since building a JS value off the
// loop would race the engine. Canonicalization happens here, resolving `..` and symlinks before the containment check.
@(private = "file")
fs_job_run :: proc(job: ^Fs_Job) {
    assert(job.host != nil, "a host op lost its host")
    assert(job.outcome == nil, "a host op ran twice")

    job.outcome = fs_pass(job)
}

// The pass itself, so every exit reports an outcome rather than relying on each branch to
// remember to set one.
@(private = "file")
fs_pass :: proc(job: ^Fs_Job) -> Fs_Error {
    canonical, cerr := os.get_absolute_path(job.path, job.allocator)
    if cerr != nil {
        return .Denied
    }

    if !fs_contained(job.host.root, canonical) {
        return .Denied
    }

    switch job.op {
    case .Read_File:
        // Opened once and reused: `read_entire_file` on a path would resolve and stat it a
        // second time, and the size guard has to run before the read either way.
        handle, oerr := os.open(canonical)
        if oerr != nil {
            return .Unreadable
        }

        defer os.close(handle)

        size, serr := os.file_size(handle)
        if serr != nil {
            return .Unreadable
        }

        if size > FS_MAX_FILE_BYTES {
            return .Too_Large
        }

        contents, read_err := os.read_entire_file(f = handle, allocator = job.allocator)
        if read_err != nil {
            return .Unreadable
        }

        job.contents = contents

    case .Stat:
        info, ierr := os.stat(canonical, job.allocator)
        if ierr != nil {
            return .Unreadable
        }

        job.info = info

    case .Read_Dir:
        handle, oerr := os.open(canonical)
        if oerr != nil {
            return .Unreadable
        }

        defer os.close(handle)

        entries, rerr := os.read_dir(handle, -1, job.allocator)
        if rerr != nil {
            return .Unreadable
        }

        job.entries = entries
    }

    return .None
}

// Whether `path` is `root` or sits beneath it. The separator test is what stops a sibling
// directory whose name merely starts with the root's from passing.
@(private = "file")
fs_contained :: proc(root: string, path: string) -> bool {
    assert(root != "", "containment needs a root")

    if path == root {
        return true
    }

    if !strings.has_prefix(path, root) {
        return false
    }

    rest := path[len(root):]

    return len(rest) > 0 && rest[0] == filepath.SEPARATOR
}

// Loop thread: settles the promise, releases the job, and drains the queued continuations.
// The context is guaranteed live — the embedder drains its pool before calling `destroy`.
@(private = "file")
fs_job_done :: proc(job: ^Fs_Job) {
    outcome, decided := job.outcome.?
    assert(decided, "a host op completed without an outcome")

    h := job.host
    assert(h != nil, "a host op lost its host")
    assert(h.ctx != nil, "a host op completed after its context was freed")
    assert(h.pending > 0, "a host op completed without being counted")

    defer fs_job_free(job)

    h.pending -= 1
    fs_settle(job, outcome)

    // Settling only queues the reaction; the continuations run here.
    drain(h)
}

// Call resolve or reject with what the pass decided. A settle call can only except if the
// promise was already settled, which can't happen for one this job alone owns.
@(private = "file")
fs_settle :: proc(job: ^Fs_Job, outcome: Fs_Error) {
    ctx := job.host.ctx

    defer qjs.free_value(ctx, job.resolve)
    defer qjs.free_value(ctx, job.reject)

    // The success value is built only on the success path: on a failed pass the result
    // fields were never populated.
    settle := job.reject
    value := qjs.new_string(ctx, fs_error_message(outcome)) if outcome != .None else fs_value(job)

    if outcome == .None {
        settle = job.resolve
    }

    defer qjs.free_value(ctx, value)

    args := [1]qjs.Value{value}
    qjs.free_value(ctx, qjs.call(ctx, settle, qjs.undefined(), args[:]))
}

// Build the JS value a successful pass resolves to.
@(private = "file")
fs_value :: proc(job: ^Fs_Job) -> qjs.Value {
    ctx := job.host.ctx

    switch job.op {
    case .Read_File:
        return qjs.new_string(ctx, string(job.contents))

    case .Stat:
        return fs_info_object(ctx, job.info)

    case .Read_Dir:
        list := qjs.new_array(ctx)

        for entry, i in job.entries {
            _ = qjs.set_index(ctx, list, u32(i), fs_info_object(ctx, entry))
        }

        return list
    }

    unreachable()
}

// One `File_Info` as a plain object. `name` is the basename, not the absolute path — that
// would leak the root's location into the sandbox.
@(private = "file")
fs_info_object :: proc(ctx: ^qjs.Context, info: os.File_Info) -> qjs.Value {
    obj := qjs.new_object(ctx)

    _ = qjs.set_property(ctx, obj, "name", qjs.new_string(ctx, filepath.base(info.fullpath)))
    _ = qjs.set_property(ctx, obj, "size", qjs.new_f64(f64(info.size)))
    _ = qjs.set_property(ctx, obj, "isDirectory", qjs.new_bool(info.type == .Directory))
    _ = qjs.set_property(ctx, obj, "isFile", qjs.new_bool(info.type == .Regular))

    return obj
}

@(private = "file")
fs_error_message :: proc(err: Fs_Error) -> string {
    switch err {
    case .None:
        unreachable()

    case .Denied:
        return "path is outside the js root"

    case .Unreadable:
        return "path could not be read"

    case .Too_Large:
        return "file is too large to read"
    }

    unreachable()
}

// Release the job's arena and the job. Every owned path, buffer, and entry lives in the
// arena, so nothing is reachable afterwards.
@(private = "file")
fs_job_free :: proc(job: ^Fs_Job) {
    assert(job != nil, "host op cleanup needs job state")
    assert(job.host != nil, "host op cleanup lost its host")

    allocator := job.host.allocator
    mem.dynamic_arena_destroy(&job.arena)

    free(job, allocator)
}
