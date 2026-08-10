package js

import "base:runtime"
import "core:c"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import qjs "libs:bindings/quickjs"
import "libs:offload"

// Read-only filesystem access rooted at `Host.root`; needs root and pool.
FS_MODULE :: "yuke:fs"

// Declared up front because ES modules resolve bindings before any module body runs.
@(rodata)
FS_EXPORTS := []string{"fs"}

// Throws unless the host was given a root and a pool.
fs_module :: proc() -> Module {
    return {name = FS_MODULE, init = fs_module_init, exports = FS_EXPORTS}
}

// Max file `readFile` materializes; result is held until the promise settles.
FS_MAX_FILE_BYTES :: 8 * mem.Megabyte

// Job arena block size equals OOB threshold so mid-sized reads fit one path.
FS_JOB_BLOCK_BYTES :: 2 * mem.Kilobyte

Fs_Op :: enum {
    Read_File,
    Stat,
    Read_Dir,
}

// Peer/input failures become rejected promises, never assertions.
Fs_Error :: enum {
    None,
    Denied,
    Unreadable,
    Too_Large,
}

// One in-flight yuke:fs call; Host.pending counts these (settle Values live in the context).
Fs_Job :: struct {
    task:      offload.Task(Fs_Job),
    host:      ^Host,
    op:        Fs_Op,
    path:      string,
    resolve:   qjs.Value,
    reject:    qjs.Value,
    outcome:   Maybe(Fs_Error),
    contents:  []byte,
    info:      os.File_Info,
    entries:   []os.File_Info,
    // Process heap, not host allocator: worker is sole writer while loop uses host's.
    arena:     mem.Dynamic_Arena,
    allocator: mem.Allocator,
}

// Every export returns a promise so the single runtime is never blocked.
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

// Bad argument throws synchronously; unreadable path rejects instead.
@(private = "file")
fs_begin :: proc(ctx: ^qjs.Context, op: Fs_Op, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    h := (^Host)(qjs.get_context_opaque(ctx))

    if h == nil || h.root == "" {
        return qjs.throw_type_error(ctx, "yuke:fs needs a configured js root")
    }

    // Closed while abandoning a failed eval_module so TLA continuations cannot re-submit.
    if !h.ops_open {
        return qjs.throw_type_error(ctx, "yuke:fs is closed")
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

    // join keeps even absolute args under root; containment below is the only escape hatch.
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

// Worker: touch only `job`, never the context. Canonicalize before containment.
@(private = "file")
fs_job_run :: proc(job: ^Fs_Job) {
    assert(job.host != nil, "a host op lost its host")
    assert(job.outcome == nil, "a host op ran twice")

    job.outcome = fs_pass(job)
}

@(private = "file")
fs_pass :: proc(job: ^Fs_Job) -> Fs_Error {
    canonical, cerr := os.get_absolute_path(job.path, job.allocator)
    if cerr != nil {
        return .Denied
    }

    if !path_contained(job.host.root, canonical) {
        return .Denied
    }

    switch job.op {
    case .Read_File:
        // Open once: size guard must run before materializing the read.
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

// Path is root or beneath it; separator test stops sibling prefix matches.
// Shared by yuke:fs (canonical) and the module loader resolver (normalized).
path_contained :: proc(root: string, path: string) -> bool {
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

// Loop thread: settle, free job, drain. Context is live — embedder drains before destroy.
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

    // Settling only queues the reaction; continuations run here.
    drain(h)
}

// Settle can only except if already settled, which cannot happen for a job-owned promise.
@(private = "file")
fs_settle :: proc(job: ^Fs_Job, outcome: Fs_Error) {
    ctx := job.host.ctx

    defer qjs.free_value(ctx, job.resolve)
    defer qjs.free_value(ctx, job.reject)

    // Success value only on success: failed passes never populated result fields.
    settle := job.reject
    value := qjs.new_string(ctx, fs_error_message(outcome)) if outcome != .None else fs_value(job)

    if outcome == .None {
        settle = job.resolve
    }

    defer qjs.free_value(ctx, value)

    args := [1]qjs.Value{value}
    qjs.free_value(ctx, qjs.call(ctx, settle, qjs.undefined(), args[:]))
}

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

// `name` is basename only — absolute paths would leak the root into the sandbox.
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

// Arena owns every path/buffer/entry; nothing is reachable after destroy.
@(private = "file")
fs_job_free :: proc(job: ^Fs_Job) {
    assert(job != nil, "host op cleanup needs job state")
    assert(job.host != nil, "host op cleanup lost its host")

    allocator := job.host.allocator
    mem.dynamic_arena_destroy(&job.arena)

    free(job, allocator)
}
