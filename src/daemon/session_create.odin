package daemon

import "core:crypto"
import "core:log"
import "core:mem"
import "core:strings"

import store "src:daemon/store"
import wire "src:wire"

// `session.create`: resolve the requested root off the reactor, then register the
// workspace and the session together.
method_session_create :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "session.create needs connection state")
    assert(conn.state == .Ready, "session.create ran outside Ready")
    assert(req.method == .Session_Create, "session.create received another method")

    // `request_validate` already held every override to the bound of the `Session` field
    // it lands in, so the summary this builds cannot overflow.
    params := req.params.(wire.Create_Session)

    fs_job_submit(conn, req.id, .Create_Session, fs_target_path(params.workspace_path, sa), create = params)
}

// The compact index revision every announcement and snapshot carries. Daemon-lifetime, so
// a client that reconnects sees it restart and refetches; minted from 1 because the wire
// reserves 0 for "this daemon has changed nothing yet".
@(private = "file")
session_revision_next :: proc(d: ^Daemon) -> wire.Session_Revision {
    assert(d != nil, "a session index revision needs daemon state")
    assert(u64(d.session_revision) < wire.MAX_SESSION_REVISION, "the session index revision is exhausted")

    d.session_revision += 1

    return d.session_revision
}

// Persist the session into its resolved workspace and answer. `workspace.created` is
// announced first, so a client is never told about a session in a workspace it has never
// heard of.
session_send_create :: proc(conn: ^Conn, job: ^Fs_Job) {
    assert(job.kind == .Create_Session, "a session was built from another job")
    assert(len(job.canonical) > 0, "a completed create has a canonical root")
    assert(conn.daemon != nil, "session.create needs daemon state")
    assert(conn.daemon.store != nil, "a serving daemon always owns an event store")

    d := conn.daemon
    workspace := wire.Workspace {
        id    = workspace_id(job.canonical),
        root  = job.canonical,
        title = workspace_title(job.canonical),
    }

    session := session_from_create(job, workspace.id, conn)

    // Only an explicit value is stored. An omitted prompt has no config layer to resolve
    // against yet, and an explicit null forces none; both read back as `null`.
    prompt: Maybe(string)
    if set, ok := job.create.system_prompt.(wire.System_Prompt_Set); ok {
        prompt = set.value
    }

    workspace_created, err := store.session_create(d.store, workspace, session, prompt)
    if err != nil {
        log.errorf("daemon: session.create could not persist the session: %v", err)
        send_error(conn, job.id, .Internal, "could not create session", job.allocator)

        return
    }

    if workspace_created {
        _ = broadcast(d, wire.Workspace_Created_Data{workspace = workspace})
    }

    _ = broadcast(d, wire.Session_Summary_Changed_Data{revision = session_revision_next(d), session = session})

    // A failed fan-out aborts the connection it failed on, and a relay connection is freed
    // synchronously by that abort — including the one that asked. The session is durable
    // either way; only the answer is lost.
    answer := conn_resolve(d, job.ticket)
    if answer == nil {
        return
    }

    send_result(answer, job.id, wire.Session_Result{session = session}, job.allocator)
}

// Build the summary a create persists and announces. Every omitted override takes its
// documented default; nothing is resolved against the catalog, which the run path does
// with better information than creation has. The client identity is cloned into the job,
// which outlives every connection the broadcasts can tear down.
@(private = "file")
session_from_create :: proc(job: ^Fs_Job, workspace: wire.Workspace_Id, conn: ^Conn) -> wire.Session {
    now := now_ms()
    session := wire.Session {
        id = session_id_create(),
        workspace_id = workspace,
        profile = "default",
        permission = .Normal,
        created_at_ms = now,
        updated_at_ms = now,
        created_by = wire.Client {
            name = strings.clone(conn.client_name, job.allocator),
            version = strings.clone(conn.client_version, job.allocator),
        },
        origin = wire.Session_Origin_Root{},
    }

    if profile, ok := job.create.profile.?; ok {
        session.profile = profile
    }

    if model, ok := job.create.model.?; ok {
        session.model = model
    }

    if reasoning, ok := job.create.reasoning.?; ok {
        session.reasoning = reasoning
    }

    if permission, ok := job.create.permission.?; ok {
        session.permission = permission
    }

    // `default` and an explicit null are the same live state: no cap. Only `set` carries one.
    if max_rounds, ok := job.create.max_rounds.(wire.Max_Rounds_Set); ok {
        session.max_rounds = max_rounds.value
    }

    return session
}

// A fresh session id: 8 random bytes rendered as the 16 lowercase hex chars the wire
// fixes, which the store also uses as the session's name.
@(private = "file")
session_id_create :: proc() -> wire.Session_Id {
    random: [8]byte
    crypto.rand_bytes(random[:])

    lower := "0123456789abcdef"
    out: [16]byte
    for value, index in random {
        out[index * 2] = lower[value >> 4]
        out[index * 2 + 1] = lower[value & 0x0f]
    }

    id := wire.Session_Id(out)
    assert(wire.enforce_id(([16]u8)(id)) == .None, "a minted session id is a valid wire id")

    return id
}
