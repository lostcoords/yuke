package js

import "base:runtime"
import "core:c"
import "core:crypto/sha2"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import qjs "libs:bindings/quickjs"
import "libs:offload"

// Filesystem access for host scripts. Every path follows `path_resolve`; nothing here is
// contained, because a caller that also has `yuke:exec` could walk around any containment.
FS_MODULE :: "yuke:fs"

// Declared up front because ES modules resolve bindings before any module body runs. Flat
// exports rather than one object: `import * as fs from "yuke:fs"` still reads as a namespace.
@(rodata)
FS_EXPORTS := []string{"readFile", "writeFile", "edit", "readDir", "stat", "exists", "hash"}

// Largest file `readFile` materializes or `hash` digests; the result is held until the
// promise settles.
FS_MAX_FILE_BYTES :: 8 * mem.Megabyte

// Job arena block size; a mid-sized read fits one block.
@(private = "file")
FS_JOB_BLOCK_BYTES :: 64 * mem.Kilobyte

// Throws unless the host was given a pool.
fs_module :: proc() -> Module {
    return {name = FS_MODULE, init = fs_module_init, exports = FS_EXPORTS}
}

@(private = "file")
Fs_Op :: enum {
    Read_File,
    Write_File,
    Edit,
    Read_Dir,
    Stat,
    Exists,
    Hash,
}

// Script and input failures become rejected promises, never assertions.
@(private = "file")
Fs_Error :: enum {
    None,
    Unreadable,
    Unwritable,
    Too_Large,
    No_Match,
    Ambiguous,
    Canceled,
}

// One in-flight call. Inputs are cloned into `arena` on the loop thread and the worker writes
// only into the same arena, so neither side touches the other's allocator.
@(private = "file")
Fs_Job :: struct {
    task:        offload.Task(Fs_Job),
    host:        ^Host,
    cancel:      ^Run_Scope,
    op:          Fs_Op,
    path:        string,
    text:        string,
    replacement: string,
    replace_all: bool,
    outcome:     Maybe(Fs_Error),
    contents:    []byte,
    count:       int,
    present:     bool,
    digest:      string,
    info:        os.File_Info,
    entries:     []os.File_Info,
    resolve:     qjs.Value,
    reject:      qjs.Value,
    arena:       mem.Dynamic_Arena,
    allocator:   mem.Allocator,
}

// Every export returns a promise so the single runtime is never blocked.
@(private = "file")
fs_module_init :: proc "c" (ctx: ^qjs.Context, m: ^qjs.Module_Def) -> c.int {
    context = runtime.default_context()

    exports := [?]struct {
        name:  cstring,
        entry: qjs.C_Function,
        argc:  int,
    } {
        {"readFile", fs_read_file, 1},
        {"writeFile", fs_write_file, 2},
        {"edit", fs_edit, 4},
        {"readDir", fs_read_dir, 1},
        {"stat", fs_stat, 1},
        {"exists", fs_exists, 1},
        {"hash", fs_hash, 1},
    }
    for export in exports {
        if !qjs.set_module_export(ctx, m, export.name, qjs.new_function(ctx, export.entry, export.name, export.argc)) {
            return -1
        }
    }

    return 0
}

@(private = "file")
fs_read_file :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()

    job, thrown, ok := fs_begin(ctx, .Read_File, argc, argv)
    if !ok {
        return thrown
    }

    return fs_submit(ctx, job)
}

@(private = "file")
fs_write_file :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()

    job, thrown, ok := fs_begin(ctx, .Write_File, argc, argv)
    if !ok {
        return thrown
    }

    if failure, got := arg_string(ctx, argv, argc, 1, job.allocator, &job.text); !got {
        fs_job_free(job)

        return failure
    }

    return fs_submit(ctx, job)
}

// `edit(path, oldText, newText, replaceAll?)` — the target is named by content, because a
// line number goes stale the moment anything above it changes.
@(private = "file")
fs_edit :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()

    job, thrown, ok := fs_begin(ctx, .Edit, argc, argv)
    if !ok {
        return thrown
    }

    fields := [2]^string{&job.text, &job.replacement}

    for out, index in fields {
        if failure, got := arg_string(ctx, argv, argc, c.int(index) + 1, job.allocator, out); !got {
            fs_job_free(job)

            return failure
        }
    }

    if argc > 3 && !qjs.is_undefined(argv[3]) {
        replace_all, read := qjs.to_bool(ctx, argv[3])

        if !read {
            fs_job_free(job)

            return qjs.throw_type_error(ctx, "yuke:fs edit expects a boolean replaceAll")
        }

        job.replace_all = replace_all
    }

    return fs_submit(ctx, job)
}

@(private = "file")
fs_read_dir :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()

    job, thrown, ok := fs_begin(ctx, .Read_Dir, argc, argv)
    if !ok {
        return thrown
    }

    return fs_submit(ctx, job)
}

@(private = "file")
fs_stat :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()

    job, thrown, ok := fs_begin(ctx, .Stat, argc, argv)
    if !ok {
        return thrown
    }

    return fs_submit(ctx, job)
}

@(private = "file")
fs_exists :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()

    job, thrown, ok := fs_begin(ctx, .Exists, argc, argv)
    if !ok {
        return thrown
    }

    return fs_submit(ctx, job)
}

@(private = "file")
fs_hash :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()

    job, thrown, ok := fs_begin(ctx, .Hash, argc, argv)
    if !ok {
        return thrown
    }

    return fs_submit(ctx, job)
}

// Allocate the job, its arena, and its path. A bad argument throws synchronously; an
// unusable path rejects later, because only the worker can tell.
@(private = "file")
fs_begin :: proc(ctx: ^qjs.Context, op: Fs_Op, argc: c.int, argv: [^]qjs.Value) -> (^Fs_Job, qjs.Value, bool) {
    h := host_of(ctx)

    if h == nil || h.pool == nil {
        return nil, qjs.throw_type_error(ctx, "yuke:fs needs a configured worker pool"), false
    }

    // Closed while abandoning a failed eval so continuations cannot re-submit.
    if !h.ops_open {
        return nil, qjs.throw_type_error(ctx, "yuke:fs is closed"), false
    }

    job := new(Fs_Job, h.allocator)

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

    signal_index: c.int
    switch op {
    case .Read_File, .Read_Dir, .Stat, .Exists, .Hash:
        signal_index = 1

    case .Write_File:
        signal_index = 2

    case .Edit:
        signal_index = 4
    }

    cancel, cancel_thrown, cancel_ok := cancel_arg(ctx, argc, argv, signal_index)
    if !cancel_ok {
        fs_job_free(job)

        return nil, cancel_thrown, false
    }
    job.cancel = cancel
    cancel_retain(cancel)

    requested: string

    if thrown, got := arg_string(ctx, argv, argc, 0, job.allocator, &requested); !got {
        fs_job_free(job)

        return nil, thrown, false
    }

    resolved, resolved_ok := path_resolve(h.base, requested, job.allocator)
    if !resolved_ok {
        fs_job_free(job)

        return nil, qjs.throw_type_error(ctx, "yuke:fs expects an absolute path"), false
    }

    job.path = resolved

    return job, qjs.undefined(), true
}

@(private = "file")
fs_submit :: proc(ctx: ^qjs.Context, job: ^Fs_Job) -> qjs.Value {
    promise, resolve, reject := qjs.new_promise(ctx)
    if qjs.is_exception(promise) {
        fs_job_free(job)

        return promise
    }

    job.resolve = resolve
    job.reject = reject
    op_begin(job.host)

    offload.submit(job.host.pool, job, fs_job_run, fs_job_done)

    return promise
}

// Worker: touch only `job`, never the context.
@(private = "file")
fs_job_run :: proc(job: ^Fs_Job) {
    assert(job.host != nil, "a host op lost its host")
    assert(job.outcome == nil, "a host op ran twice")

    job.outcome = .Canceled if fs_job_cancelled(job) else fs_pass(job)
}

@(private = "file")
fs_pass :: proc(job: ^Fs_Job) -> Fs_Error {
    switch job.op {
    case .Read_File:
        contents, err := fs_read_contents(job)
        job.contents = transmute([]byte)contents

        return err

    case .Write_File:
        return fs_write_contents(job)

    case .Edit:
        return fs_edit_contents(job)

    case .Read_Dir:
        handle, oerr := os.open(job.path)
        if oerr != nil {
            return .Unreadable
        }

        defer os.close(handle)

        entries, rerr := os.read_dir(handle, -1, job.allocator)
        if rerr != nil {
            return .Unreadable
        }

        job.entries = entries

        return .None

    case .Stat:
        info, ierr := os.stat(job.path, job.allocator)
        if ierr != nil {
            return .Unreadable
        }

        job.info = info

        return .None

    case .Exists:
        job.present = os.exists(job.path)

        return .None

    case .Hash:
        return fs_hash_contents(job)
    }

    unreachable()
}

@(private = "file")
fs_read_contents :: proc(job: ^Fs_Job) -> (contents: string, err: Fs_Error) {
    handle, oerr := os.open(job.path)
    if oerr != nil {
        return "", .Unreadable
    }

    defer os.close(handle)

    // Open once: the size guard must run before the read materializes anything.
    size, serr := os.file_size(handle)
    if serr != nil {
        return "", .Unreadable
    }

    if size > FS_MAX_FILE_BYTES {
        return "", .Too_Large
    }

    data, rerr := os.read_entire_file(f = handle, allocator = job.allocator)
    if rerr != nil {
        return "", .Unreadable
    }

    return string(data), .None
}

@(private = "file")
fs_write_contents :: proc(job: ^Fs_Job) -> Fs_Error {
    if fs_job_cancelled(job) {
        return .Canceled
    }

    // Writing a new file in a new directory is ordinary, so the parents are made rather than
    // reported as a missing-path failure.
    if parent := filepath.dir(job.path); parent != "" {
        if mkerr := os.make_directory_all(parent); mkerr != nil && !os.is_dir(parent) {
            return .Unwritable
        }
    }

    if fs_job_cancelled(job) {
        return .Canceled
    }

    if werr := os.write_entire_file(job.path, transmute([]byte)job.text); werr != nil {
        return .Unwritable
    }

    job.count = len(job.text)

    return .None
}

@(private = "file")
fs_edit_contents :: proc(job: ^Fs_Job) -> Fs_Error {
    contents, err := fs_read_contents(job)
    if err != .None {
        return err
    }

    occurrences := strings.count(contents, job.text)
    if occurrences == 0 {
        return .No_Match
    }

    if occurrences > 1 && !job.replace_all {
        return .Ambiguous
    }

    replaced, _ := strings.replace(
        contents,
        job.text,
        job.replacement,
        occurrences if job.replace_all else 1,
        job.allocator,
    )

    if fs_job_cancelled(job) {
        return .Canceled
    }

    if werr := os.write_entire_file(job.path, transmute([]byte)replaced); werr != nil {
        return .Unwritable
    }

    job.count = occurrences if job.replace_all else 1

    return .None
}

// Absent is not a failure: a null hash is how a caller tells a new file from one it has not
// read yet, which is what a read-before-edit guard is built on.
@(private = "file")
fs_hash_contents :: proc(job: ^Fs_Job) -> Fs_Error {
    if !os.exists(job.path) {
        job.present = false

        return .None
    }

    contents, err := fs_read_contents(job)
    if err != .None {
        return err
    }

    hasher: sha2.Context_256
    sha2.init_256(&hasher)
    sha2.update(&hasher, transmute([]byte)contents)

    digest: [sha2.DIGEST_SIZE_256]byte
    sha2.final(&hasher, digest[:])

    hex := make([]u8, 2 * len(digest), job.allocator)

    for value, index in digest {
        hex[index * 2] = FS_HEX_DIGITS[value >> 4]
        hex[index * 2 + 1] = FS_HEX_DIGITS[value & 0xf]
    }

    job.digest = string(hex)
    job.present = true

    return .None
}

@(private = "file", rodata)
FS_HEX_DIGITS := "0123456789abcdef"

// Loop thread: settle, free job, drain. The context is live — the embedder drains before destroy.
@(private = "file")
fs_job_done :: proc(job: ^Fs_Job) {
    outcome, decided := job.outcome.?
    assert(decided, "a host op completed without an outcome")

    h := job.host
    assert(h != nil, "a host op lost its host")
    assert(h.ctx != nil, "a host op completed after its context was freed")

    defer fs_job_free(job)

    fs_settle(job, .Canceled if fs_job_cancelled(job) else outcome)
    op_end(h)
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

    case .Write_File, .Edit:
        return qjs.new_f64(f64(job.count))

    case .Read_Dir:
        list := qjs.new_array(ctx)

        for entry, i in job.entries {
            _ = qjs.set_index(ctx, list, u32(i), fs_info_object(ctx, entry))
        }

        return list

    case .Stat:
        return fs_info_object(ctx, job.info)

    case .Exists:
        return qjs.new_bool(job.present)

    case .Hash:
        return qjs.new_string(ctx, job.digest) if job.present else qjs.null()
    }

    unreachable()
}

@(private = "file")
fs_info_object :: proc(ctx: ^qjs.Context, info: os.File_Info) -> qjs.Value {
    obj := qjs.new_object(ctx)

    _ = qjs.set_property(ctx, obj, "name", qjs.new_string(ctx, filepath.base(info.fullpath)))
    _ = qjs.set_property(ctx, obj, "path", qjs.new_string(ctx, info.fullpath))
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

    case .Unreadable:
        return "path could not be read"

    case .Unwritable:
        return "path could not be written"

    case .Too_Large:
        return "file is too large"

    case .No_Match:
        return "old text was not found"

    case .Ambiguous:
        return "old text is not unique; pass replaceAll or give more context"

    case .Canceled:
        return "operation canceled"
    }

    unreachable()
}

// The arena owns every path, buffer, and entry; nothing is reachable after destroy.
@(private = "file")
fs_job_free :: proc(job: ^Fs_Job) {
    assert(job != nil, "host op cleanup needs job state")
    assert(job.host != nil, "host op cleanup lost its host")

    allocator := job.host.allocator
    cancel_release(job.cancel)
    mem.dynamic_arena_destroy(&job.arena)

    free(job, allocator)
}

@(private = "file")
fs_job_cancelled :: proc(job: ^Fs_Job) -> bool {
    assert(job != nil && job.host != nil, "a filesystem cancellation check needs its job")

    return cancelled(job.host) || cancelled_scope(job.cancel)
}
