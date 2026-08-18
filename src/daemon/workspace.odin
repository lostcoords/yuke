package daemon

import "base:runtime"
import "core:hash"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "libs:offload"
import "src:paths"
import "src:wire"

// Derived workspace id: FNV-1a-64 over the canonical root's UTF-8 bytes, rendered as 16
// lowercase hex chars, matching the reference daemon so a directory maps to a stable id.
workspace_id :: proc(root: string) -> wire.Workspace_Id {
    assert(len(root) > 0, "workspace id needs a canonical root")

    h := hash.fnv64a(transmute([]byte)root)

    hex := "0123456789abcdef"
    out: [16]u8
    for i in 0 ..< 16 {
        out[i] = hex[(h >> uint((15 - i) * 4)) & 0xf]
    }

    id := wire.Workspace_Id(out)
    assert(wire.enforce_fixed_lower_hex(16, string(out[:])) == .None, "derived workspace id is invalid")

    return id
}

// Display title for a workspace: the canonical root's basename, falling back to the
// whole root when it has none (the filesystem root), clamped to `Workspace.title`.
workspace_title :: proc(root: string) -> string {
    assert(len(root) > 0, "workspace title needs a canonical root")

    base := os.base(root)
    title := base
    if title == "" do title = root

    return clamp_utf8_bytes(title, 256)
}

// Git status for a workspace root: null when it is not a repo, else the branch from `.git/HEAD`.
// Dirty detection needs the git binary, which this deliberately avoids, so `dirty` is always false.
git_info :: proc(root: string, allocator: mem.Allocator) -> Maybe(wire.Git_Info) {
    assert(len(root) > 0, "git info needs a canonical root")

    git_marker := strings.concatenate({root, "/.git"}, allocator)
    if !os.exists(git_marker) do return nil

    return wire.Git_Info{branch = git_branch(root, allocator), dirty = false}
}

// Current branch from `.git/HEAD`: the ref name for a symbolic HEAD, or "" for a
// detached, unreadable, or non-UTF-8 HEAD. Clamped to the `Git_Info.branch` bound.
git_branch :: proc(root: string, allocator: mem.Allocator) -> string {
    assert(len(root) > 0, "git branch needs a canonical root")

    head, err := os.read_entire_file_from_path(strings.concatenate({root, "/.git/HEAD"}, allocator), allocator)
    if err != nil do return ""

    ref := strings.trim_space(string(head))
    PREFIX :: "ref: refs/heads/"
    if !strings.has_prefix(ref, PREFIX) do return ""

    branch := ref[len(PREFIX):]

    return clamp_utf8_bytes(branch, 256)
}

// Truncate `s` to at most `max` bytes, backing off to the previous UTF-8 rune boundary.
// Filesystem bytes are untrusted: non-UTF-8 input yields "" rather than an invalid frame.
clamp_utf8_bytes :: proc(s: string, max: int) -> string {
    assert(max >= 0, "clamp_utf8_bytes: max must be non-negative")

    if !utf8.valid_string(s) do return ""

    if len(s) <= max do return s

    cut := max
    for cut > 0 && s[cut] & 0xC0 == 0x80 {
        cut -= 1
    }

    return s[:cut]
}

// The directory's modification time in epoch ms, or 0 when it cannot be stat'd.
path_mtime_ms :: proc(path: string, allocator: mem.Allocator) -> u64 {
    assert(len(path) > 0, "path mtime needs a canonical path")

    info, err := os.stat(path, allocator)
    if err != nil do return 0
    defer os.file_info_delete(info, allocator)

    ns := time.to_unix_nanoseconds(info.modification_time)
    if ns < 0 do return 0

    return u64(ns / 1_000_000)
}

// The parent-directory path of a canonicalized dir, or null at the filesystem root.
parent_dir :: proc(dir: string) -> Maybe(string) {
    assert(len(dir) > 0, "parent lookup needs a canonical directory")

    if dir == "/" do return nil

    return os.dir(dir)
}

// List one bounded page of immediate subdirectories after `cursor`. The scan retains
// only the smallest page plus one name, regardless of directory size.
browse_entries_page :: proc(
    dir: string,
    cursor: string,
    page_size: int,
    allocator: mem.Allocator,
) -> (
    entries: []wire.Dir_Entry,
    has_more: bool,
    err: os.Error,
) {
    assert(len(dir) > 0, "browse needs a canonicalized directory")
    assert(page_size > 0 && page_size <= wire.LIMITS.max_workspace_browse_page_size, "browse needs a bounded page")

    directory, open_err := os.open(dir, {.Read})
    if open_err != nil do return nil, false, open_err
    defer os.close(directory)

    iterator := os.read_directory_iterator_create(directory)
    defer os.read_directory_iterator_destroy(&iterator)

    WINDOW_MAX :: wire.LIMITS.max_workspace_browse_page_size + 1
    names: [WINDOW_MAX]string
    name_count := 0
    window_size := page_size + 1
    heap := runtime.heap_allocator()
    defer {
        for name in names[:name_count] {
            delete(name, heap)
        }
    }

    for info in os.read_directory_iterator(&iterator) {
        if info.name == ".git" do continue

        if len(info.name) > 256 do continue

        if !utf8.valid_string(info.name) || !utf8.valid_string(info.fullpath) do continue

        if cursor != "" && !dir_name_less(cursor, info.name) do continue

        insert_at := 0
        for insert_at < name_count && dir_name_less(names[insert_at], info.name) {
            insert_at += 1
        }
        if name_count == window_size && insert_at == name_count do continue

        if !file_info_is_dir(info, allocator) do continue

        cloned, clone_err := strings.clone(info.name, heap)
        if clone_err != nil do return nil, false, clone_err

        if name_count < window_size {
            name_count += 1
        } else {
            delete(names[name_count - 1], heap)
        }
        for index := name_count - 1; index > insert_at; index -= 1 {
            names[index] = names[index - 1]
        }
        names[insert_at] = cloned
    }

    if _, iterator_err := os.read_directory_iterator_error(&iterator); iterator_err != nil do return nil, false, iterator_err

    has_more = name_count > page_size
    entry_count := min(name_count, page_size)
    allocated_entries, entries_aerr := make([]wire.Dir_Entry, entry_count, allocator)
    if entries_aerr != nil do return nil, false, entries_aerr
    entries = allocated_entries

    for name, index in names[:entry_count] {
        owned_name, name_aerr := strings.clone(name, allocator)
        path, path_aerr := os.join_path({dir, name}, allocator)
        if name_aerr != nil || path_aerr != nil do return nil, false, name_aerr if name_aerr != nil else path_aerr

        git_path, git_aerr := strings.concatenate({path, "/.git"}, allocator)
        if git_aerr != nil do return nil, false, git_aerr
        entries[index] = {
            name        = owned_name,
            path        = path,
            is_git_repo = os.exists(git_path),
        }
    }

    return entries, has_more, nil
}

// Whether a directory entry resolves to a directory, following a symlink or an entry
// whose type the platform left undetermined.
file_info_is_dir :: proc(info: os.File_Info, allocator: mem.Allocator) -> bool {
    if info.type == .Directory do return true

    if info.type == .Symlink || info.type == .Undetermined {
        resolved, err := os.stat(info.fullpath, allocator)
        defer if err == nil do os.file_info_delete(resolved, allocator)

        return err == nil && resolved.type == .Directory
    }

    return false
}

// ASCII-folded ordering with a raw-byte tie break, so case variants form a total order.
dir_name_less :: proc(a, b: string) -> bool {
    n := min(len(a), len(b))

    for i in 0 ..< n {
        ca := ascii_lower(a[i])
        cb := ascii_lower(b[i])
        if ca != cb do return ca < cb
    }

    if len(a) != len(b) do return len(a) < len(b)

    return a < b
}

ascii_lower :: proc(c: u8) -> u8 {
    if c >= 'A' && c <= 'Z' do return c + 32

    return c
}

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

// Per-request filesystem state, owned across the offloaded pass and freed by the completion.
// Every field a worker touches is owned here, so the pass outlives frame arena and connection.
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

    // Owned clone of the `session.create` params, meaningful only for that kind. Held across the
    // pass: the frame arena is long gone by the time the resolved root is known.
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

    // Backs every owned allocation above and the response the completion encodes. Process heap,
    // not the daemon's allocator, since the worker is its only writer.
    arena:       mem.Dynamic_Arena,
    allocator:   mem.Allocator,
}

// An omitted path is the daemon user's home. Reading the environment touches no filesystem,
// so it resolves on the reactor and the worker only sees a concrete path.
fs_target_path :: proc(path: Maybe(string), sa: mem.Allocator) -> string {
    if p, ok := path.?; ok do return p

    if home := paths.home_dir(sa); home != "" do return home

    return "/"
}

// Clone everything the pass reads and hand it to a worker: `get_absolute_path`/`stat`/`readdir`
// have no nbio operation, so a hung path would stall every connection on the reactor.
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

    job := new(Fs_Job, d.allocator)

    job^ = {}
    job.daemon = d
    job.ticket = conn.ticket
    job.kind = kind
    job.page_size = page_size
    mem.dynamic_arena_init(&job.arena, runtime.heap_allocator(), runtime.heap_allocator())
    job.allocator = mem.dynamic_arena_allocator(&job.arena)

    job.id = wire.Request_Id(strings.clone(string(id), job.allocator))
    job.path = strings.clone(path, job.allocator)
    job.cursor = strings.clone(cursor, job.allocator)
    job.create = wire.create_session_clone(create, job.allocator)

    conn.fs_jobs += 1
    d.fs_jobs += 1
    offload.submit(&d.workers, job, fs_job_run, fs_job_done)
}

// Worker thread: records an outcome rather than answering or logging, since the connection may
// be gone and the logger is the loop's. A filesystem failure is an outcome, not an assertion.
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
    if conn == nil do return
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

// Emit the `workspace.describe` result from what the pass found. `last_used_model` is not
// reported yet.
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

// `workspace.describe`: the path walk is offloaded, and its completion reports the derived
// id, title, branch and mtime. A missing path or non-directory is `Bad_Request`.
method_workspace_describe :: proc(conn: ^Conn, req: wire.Request) {
    assert(conn != nil, "workspace.describe needs connection state")
    assert(conn.state == .Ready, "workspace.describe ran outside Ready")
    assert(req.method == .Workspace_Describe, "workspace.describe received another method")

    params := req.params.(wire.Workspace_Describe_Params)
    fs_job_submit(conn, req.id, .Describe, params.path)
}

// `workspace.browse`: immediate subdirectories, sorted case-insensitively, paged by an opaque
// name cursor. The window is decided here and defaults to home; the listing is offloaded.
method_workspace_browse :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "workspace.browse needs connection state")
    assert(conn.state == .Ready, "workspace.browse ran outside Ready")
    assert(req.method == .Workspace_Browse, "workspace.browse received another method")

    params := req.params.(wire.Workspace_Browse_Params)

    cursor := ""
    if requested_cursor, ok := params.cursor.?; ok do cursor = requested_cursor

    // Page size is already validated to be within bounds; default when omitted.
    page_size := wire.LIMITS.default_workspace_browse_page_size
    if limit, ok := params.limit.?; ok do page_size = int(limit)

    fs_job_submit(conn, req.id, .Browse, fs_target_path(params.path, sa), cursor, page_size)
}
