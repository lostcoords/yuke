package daemon

import "base:runtime"
import "core:mem"
import "core:os"
import "core:strings"

import "libs:offload"
import "src:paths"
import wire "src:wire"

FS_JOBS_PER_CONN_MAX :: 4
FS_JOBS_GLOBAL_MAX :: 64

// Which method a job answers. All three begin with the same canonicalization, then
// diverge into a describe, a listing, or a session created into the resolved root.
Fs_Job_Kind :: enum {
    Describe,
    Browse,
    Create_Session,
}

// What the filesystem pass decided. Recorded on a worker thread, which can neither answer
// the request nor log, and turned into a response by the completion back on the loop.
Fs_Outcome :: enum {
    // The pass completed; the result fields below are populated.
    Ready,

    // The requested path could not be canonicalized.
    Invalid_Path,

    // The path canonicalized to something that is not a directory; a session and a
    // describe both need a root to run in.
    Not_A_Directory,

    // `workspace.browse` could not read the directory.
    Unreadable,
}

// Per-request filesystem state, owned across the offloaded pass and freed by the
// completion. Every field a worker touches is owned here, not borrowed, so the pass
// outlives both the frame arena it was decoded from and its connection.
Fs_Job :: struct {
    // Walks the filesystem off the reactor; carried here so submitting never allocates.
    task:        offload.Task(Fs_Job),

    // Owning daemon, for the worker pool and the connection table.
    daemon:      ^Daemon,

    // Connection to answer, resolved again on the loop: the `Conn` may be gone by then.
    ticket:      Conn_Ticket,

    // Which method this answers.
    kind:        Fs_Job_Kind,

    // Owned clone of the request id the response correlates against.
    id:          wire.Request_Id,

    // Owned clone of the requested path, already defaulted for `workspace.browse`.
    path:        string,

    // Browse page window, decided from the params before submission.
    cursor:      string,
    page_size:   int,

    // Owned clone of the `session.create` params; meaningful only for that kind. Held
    // across the pass because the frame arena they were decoded from is long gone by
    // the time the resolved root is known.
    create:      wire.Create_Session,

    // What the pass decided. Nil until the worker finishes.
    outcome:     Maybe(Fs_Outcome),

    // Canonicalized path; set only on `.Ready`.
    canonical:   string,

    // `workspace.describe` findings.
    git:         Maybe(wire.Git_Info),
    modified_ms: u64,

    // `workspace.browse` page and whether another page follows.
    entries:     []wire.Dir_Entry,
    has_more:    bool,

    // Backs every owned allocation above and the response the completion encodes. Blocks
    // come from the process heap, not the daemon's allocator, since the worker is its
    // only writer.
    arena:       mem.Dynamic_Arena,
    allocator:   mem.Allocator,
}

// An omitted path is the daemon user's home. Reading the environment touches no
// filesystem, so it is resolved on the reactor and the worker only ever sees a concrete
// path.
fs_target_path :: proc(path: Maybe(string), sa: mem.Allocator) -> string {
    if p, ok := path.?; ok {
        return p
    }

    if home := paths.home_dir(sa); home != "" {
        return home
    }

    return "/"
}

// Clone everything the pass reads out of the frame arena and hand it to a worker:
// `get_absolute_path`/`stat`/`readdir` have no nbio operation, so a bad path (a hung
// mount, a FIFO with no writer) would stall every connection run on the reactor.
fs_job_submit :: proc(
    conn: ^Conn,
    id: wire.Request_Id,
    kind: Fs_Job_Kind,
    path: string,
    cursor := "",
    page_size := 0,
    create := wire.Create_Session{},
) {
    assert(conn != nil, "filesystem job needs connection state")
    assert(conn.daemon != nil, "filesystem job needs daemon state")
    assert(conn.state == .Ready, "filesystem job submitted outside Ready")
    assert(conn.ticket != 0, "filesystem job needs a resolvable connection")
    assert(page_size >= 0, "filesystem job needs a non-negative page size")

    d := conn.daemon
    assert(conn.fs_jobs >= 0 && d.fs_jobs >= 0, "filesystem job counts stay non-negative")
    if conn.fs_jobs >= FS_JOBS_PER_CONN_MAX || d.fs_jobs >= FS_JOBS_GLOBAL_MAX {
        send_error(conn, id, .Overloaded, "too many filesystem operations are in progress", conn.allocator)
        return
    }

    job, aerr := new(Fs_Job, d.allocator)
    if aerr != nil {
        conn_abort(conn, .Out_Of_Memory)
        return
    }

    job^ = {}
    job.daemon = d
    job.ticket = conn.ticket
    job.kind = kind
    job.page_size = page_size
    mem.dynamic_arena_init(&job.arena, runtime.heap_allocator(), runtime.heap_allocator())
    job.allocator = mem.dynamic_arena_allocator(&job.arena)

    cloned_id, id_aerr := strings.clone(string(id), job.allocator)
    cloned_path, path_aerr := strings.clone(path, job.allocator)
    cloned_cursor, cursor_aerr := strings.clone(cursor, job.allocator)
    if id_aerr != nil || path_aerr != nil || cursor_aerr != nil {
        fs_job_free(job)
        conn_abort(conn, .Out_Of_Memory)
        return
    }

    job.id = wire.Request_Id(cloned_id)
    job.path = cloned_path
    job.cursor = cloned_cursor
    job.create = wire.create_session_clone(create, job.allocator)

    conn.fs_jobs += 1
    d.fs_jobs += 1
    offload.submit(&d.workers, job, fs_job_run, fs_job_done)
}

// Worker thread. Records an outcome rather than answering or logging — there may be no
// connection left to answer, and the logger belongs to the loop thread. A filesystem
// failure is an operating outcome, never an assertion.
fs_job_run :: proc(job: ^Fs_Job) {
    assert(job.daemon != nil, "filesystem pass lost its daemon")
    assert(job.outcome == nil, "filesystem pass ran on a finished job")
    assert(job.canonical == "" && job.entries == nil, "filesystem pass ran twice")

    canonical, cerr := os.get_absolute_path(job.path, job.allocator)
    if cerr != nil {
        job.outcome = .Invalid_Path
        return
    }

    // A session and a describe both need a root to run in; browse reports its own failure
    // by trying to read the directory.
    if job.kind != .Browse && !os.is_dir(canonical) {
        job.outcome = .Not_A_Directory
        return
    }

    switch job.kind {
    case .Describe:
        job.git = git_info(canonical, job.allocator)
        job.modified_ms = path_mtime_ms(canonical, job.allocator)

    case .Create_Session:
    // Canonicalizing the root is the whole pass; the session is built on the loop.

    case .Browse:
        entries, has_more, lerr := browse_entries_page(canonical, job.cursor, job.page_size, job.allocator)
        if lerr != nil {
            job.outcome = .Unreadable
            return
        }

        job.entries = entries
        job.has_more = has_more
    }

    job.canonical = canonical
    job.outcome = .Ready
}

// Loop thread. Answers the request if the connection is still there and frees the job
// either way; a gone connection simply has nobody to tell.
fs_job_done :: proc(job: ^Fs_Job) {
    outcome, decided := job.outcome.?
    assert(decided, "filesystem pass completed without an outcome")
    defer fs_job_free(job)

    d := job.daemon
    assert(d.fs_jobs > 0, "filesystem completion needs a live global job")
    d.fs_jobs -= 1

    conn := conn_resolve(d, job.ticket)
    if conn == nil {
        return
    }
    assert(conn.fs_jobs > 0, "filesystem completion needs a live connection job")
    conn.fs_jobs -= 1

    switch outcome {
    case .Invalid_Path:
        message := job.kind == .Browse ? "cannot open path" : "invalid workspace path"
        send_error(conn, job.id, .Bad_Request, message, job.allocator)

    case .Not_A_Directory:
        assert(job.kind != .Browse, "browse reports an unreadable directory, not a non-directory")
        send_error(conn, job.id, .Bad_Request, "workspace path is not a directory", job.allocator)

    case .Unreadable:
        assert(job.kind == .Browse, "only browse reads a directory")
        send_error(conn, job.id, .Bad_Request, "cannot list path", job.allocator)

    case .Ready:
        switch job.kind {
        case .Create_Session:
            session_send_create(conn, job)

        case .Describe:
            workspace_send_describe(conn, job)

        case .Browse:
            workspace_send_browse(conn, job)
        }
    }
}

// Emit the `workspace.describe` result from what the pass found. With no session engine
// yet, there is no `last_used_model`.
workspace_send_describe :: proc(conn: ^Conn, job: ^Fs_Job) {
    assert(job.kind == .Describe, "describe result built from another job")
    assert(len(job.canonical) > 0, "a completed describe has a canonical root")

    result := wire.Workspace_Describe_Result {
        workspace = wire.Workspace {
            id = workspace_id(job.canonical),
            root = job.canonical,
            title = workspace_title(job.canonical),
        },
        git = job.git,
        last_modified_ms = job.modified_ms,
        last_used_model = nil,
    }

    send_result(conn, job.id, result, job.allocator)
}

// Emit the bounded `workspace.browse` page prepared by the worker.
workspace_send_browse :: proc(conn: ^Conn, job: ^Fs_Job) {
    assert(job.kind == .Browse, "browse result built from another job")
    assert(len(job.canonical) > 0, "a completed browse has a canonical directory")

    next_cursor: Maybe(string)
    if job.has_more {
        assert(len(job.entries) == job.page_size, "a continuing browse page is full")
        next_cursor = job.entries[len(job.entries) - 1].name
    }

    result := wire.Workspace_Browse_Result {
        path        = job.canonical,
        parent      = parent_dir(job.canonical),
        entries     = job.entries,
        next_cursor = next_cursor,
    }

    send_result(conn, job.id, result, job.allocator)
}

// Release the job's arena and the `Fs_Job`. Every owned string and entry lives in
// the arena, so nothing is reachable afterwards.
fs_job_free :: proc(job: ^Fs_Job) {
    assert(job != nil, "filesystem job cleanup needs job state")
    assert(job.daemon != nil, "filesystem job cleanup lost its daemon")

    mem.dynamic_arena_destroy(&job.arena)

    free(job, job.daemon.allocator)
}
