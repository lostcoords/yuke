package daemon

import "base:runtime"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

import "libs:offload"
import wire "src:wire"

// Which `workspace.*` method a job answers. Both begin with the same canonicalization,
// then diverge into a describe or a listing.
Workspace_Job_Kind :: enum {
    Describe,
    Browse,
}

// What the filesystem pass decided. Recorded on a worker thread, which can neither answer
// the request nor log, and turned into a response by the completion back on the loop.
Workspace_Outcome :: enum {
    // The pass completed; the result fields below are populated.
    Ready,

    // The requested path could not be canonicalized.
    Invalid_Path,

    // `workspace.describe` canonicalized to something that is not a directory.
    Not_A_Directory,

    // `workspace.browse` could not read the directory.
    Unreadable,
}

// Per-request `workspace.*` state, owned across the offloaded pass and freed by the
// completion. Every field a worker touches is owned here, not borrowed, so the pass
// outlives both the frame arena it was decoded from and its connection.
Workspace_Job :: struct {
    // Walks the filesystem off the reactor; carried here so submitting never allocates.
    task:        offload.Task(Workspace_Job),

    // Owning daemon, for the worker pool and the connection table.
    daemon:      ^Daemon,

    // Connection to answer, resolved again on the loop: the `Conn` may be gone by then.
    ticket:      Conn_Ticket,

    // Which method this answers.
    kind:        Workspace_Job_Kind,

    // Owned clone of the request id the response correlates against.
    id:          wire.Request_Id,

    // Owned clone of the requested path, already defaulted for `workspace.browse`.
    path:        string,

    // Browse page window, decided from the params before submission.
    offset:      int,
    page_size:   int,

    // What the pass decided. Nil until the worker finishes.
    outcome:     Maybe(Workspace_Outcome),

    // Canonicalized path; set only on `.Ready`.
    canonical:   string,

    // `workspace.describe` findings.
    git:         Maybe(wire.Git_Info),
    modified_ms: u64,

    // `workspace.browse` listing, whole and sorted; the loop pages it.
    entries:     []wire.Dir_Entry,

    // Backs every owned allocation above and the response the completion encodes. Blocks
    // come from the process heap, not the daemon's allocator, since the worker is its
    // only writer.
    arena:       mem.Dynamic_Arena,
    allocator:   mem.Allocator,
}

// Clone everything the pass reads out of the frame arena and hand it to a worker:
// `get_absolute_path`/`stat`/`readdir` have no nbio operation, so a bad path (a hung
// mount, a FIFO with no writer) would stall every connection run on the reactor.
workspace_job_submit :: proc(
    conn: ^Conn,
    id: wire.Request_Id,
    kind: Workspace_Job_Kind,
    path: string,
    offset: int,
    page_size: int,
) {
    assert(conn != nil, "workspace job needs connection state")
    assert(conn.daemon != nil, "workspace job needs daemon state")
    assert(conn.state == .Ready, "workspace job submitted outside Ready")
    assert(conn.ticket != 0, "workspace job needs a resolvable connection")
    assert(offset >= 0 && page_size >= 0, "workspace job needs a non-negative page window")

    d := conn.daemon

    job, aerr := new(Workspace_Job, d.allocator)
    if aerr != nil {
        conn_abort(conn, .Out_Of_Memory)
        return
    }

    job^ = {}
    job.daemon = d
    job.ticket = conn.ticket
    job.kind = kind
    job.offset = offset
    job.page_size = page_size
    mem.dynamic_arena_init(&job.arena, runtime.heap_allocator(), runtime.heap_allocator())
    job.allocator = mem.dynamic_arena_allocator(&job.arena)

    cloned_id, id_aerr := strings.clone(string(id), job.allocator)
    cloned_path, path_aerr := strings.clone(path, job.allocator)
    if id_aerr != nil || path_aerr != nil {
        workspace_job_free(job)
        conn_abort(conn, .Out_Of_Memory)
        return
    }

    job.id = wire.Request_Id(cloned_id)
    job.path = cloned_path

    offload.submit(&d.workers, job, workspace_job_run, workspace_job_done)
}

// Worker thread. Records an outcome rather than answering or logging — there may be no
// connection left to answer, and the logger belongs to the loop thread. A filesystem
// failure is an operating outcome, never an assertion.
workspace_job_run :: proc(job: ^Workspace_Job) {
    assert(job.daemon != nil, "workspace pass lost its daemon")
    assert(job.outcome == nil, "workspace pass ran on a finished job")
    assert(job.canonical == "" && job.entries == nil, "workspace pass ran twice")

    canonical, cerr := os.get_absolute_path(job.path, job.allocator)
    if cerr != nil {
        job.outcome = .Invalid_Path
        return
    }

    switch job.kind {
    case .Describe:
        if !os.is_dir(canonical) {
            job.outcome = .Not_A_Directory
            return
        }

        job.git = git_info(canonical, job.allocator)
        job.modified_ms = path_mtime_ms(canonical, job.allocator)

    case .Browse:
        entries, lerr := browse_entries(canonical, job.allocator)
        if lerr != nil {
            job.outcome = .Unreadable
            return
        }

        job.entries = entries
    }

    job.canonical = canonical
    job.outcome = .Ready
}

// Loop thread. Answers the request if the connection is still there and frees the job
// either way; a gone connection simply has nobody to tell.
workspace_job_done :: proc(job: ^Workspace_Job) {
    outcome, decided := job.outcome.?
    assert(decided, "workspace pass completed without an outcome")
    defer workspace_job_free(job)

    conn := conn_resolve(job.daemon, job.ticket)
    if conn == nil {
        return
    }

    switch outcome {
    case .Invalid_Path:
        message := job.kind == .Describe ? "invalid workspace path" : "cannot open path"
        send_error(conn, job.id, .Bad_Request, message, job.allocator)

    case .Not_A_Directory:
        assert(job.kind == .Describe, "only describe rejects a non-directory")
        send_error(conn, job.id, .Bad_Request, "workspace path is not a directory", job.allocator)

    case .Unreadable:
        assert(job.kind == .Browse, "only browse reads a directory")
        send_error(conn, job.id, .Bad_Request, "cannot list path", job.allocator)

    case .Ready:
        switch job.kind {
        case .Describe:
            workspace_send_describe(conn, job)

        case .Browse:
            workspace_send_browse(conn, job)
        }
    }
}

// Emit the `workspace.describe` result from what the pass found. With no session engine
// yet, there is no `last_used_model`.
workspace_send_describe :: proc(conn: ^Conn, job: ^Workspace_Job) {
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

// Emit one page of the `workspace.browse` listing. Paging is pure arithmetic over the
// sorted listing, so it runs here, not on the worker; an offset past the end is an empty
// final page, not an error.
workspace_send_browse :: proc(conn: ^Conn, job: ^Workspace_Job) {
    assert(job.kind == .Browse, "browse result built from another job")
    assert(len(job.canonical) > 0, "a completed browse has a canonical directory")

    total := len(job.entries)
    lo := min(job.offset, total)
    hi := min(lo + job.page_size, total)

    next_cursor: Maybe(string)
    cursor_buf: [24]u8
    if hi < total {
        next_cursor = strconv.write_int(cursor_buf[:], i64(hi), 10)
    }

    result := wire.Workspace_Browse_Result {
        path        = job.canonical,
        parent      = parent_dir(job.canonical),
        entries     = job.entries[lo:hi],
        next_cursor = next_cursor,
    }

    send_result(conn, job.id, result, job.allocator)
}

// Release the job's arena and the `Workspace_Job`. Every owned string and entry lives in
// the arena, so nothing is reachable afterwards.
workspace_job_free :: proc(job: ^Workspace_Job) {
    assert(job != nil, "workspace job cleanup needs job state")
    assert(job.daemon != nil, "workspace job cleanup lost its daemon")

    mem.dynamic_arena_destroy(&job.arena)

    free(job, job.daemon.allocator)
}
