package daemon

import "core:nbio"
import "core:os"
import "core:strings"
import "core:testing"

import "libs:testsupport"
import ws "libs:websocket"
import client "src:client"
import wire "src:wire"

// One driver that creates sessions and watches what the daemon announces. Both
// `workspace.created` and `session.summary_changed` are Ungated, so this connection sees
// them without subscribing to anything.
Create_Obs :: struct {
    // Requests to send, one after the previous is answered.
    requests:   []wire.Create_Session,

    // How many of `requests` have been sent.
    sent:       int,

    // Sessions returned, in request order; short when a request answered with an error.
    created:    [dynamic]wire.Session,

    // Error code of the last answered request; `is_error` says whether it means anything.
    is_error:   bool,
    code:       wire.Error_Code,

    // Broadcast names delivered, in arrival order.
    names:      [dynamic]wire.Broadcast_Name,

    // Index revision carried by each `session.summary_changed`, in arrival order.
    revisions:  [dynamic]wire.Session_Revision,

    // Workspaces the `initialize` snapshot carried.
    workspaces: []wire.Workspace,

    // Every request has been answered.
    settled:    bool,

    // Terminal callback fired.
    done:       bool,
}

create_obs_init :: proc(o: ^Create_Obs, requests: []wire.Create_Session) {
    o.requests = requests
    o.created = make([dynamic]wire.Session, context.temp_allocator)
    o.names = make([dynamic]wire.Broadcast_Name, context.temp_allocator)
    o.revisions = make([dynamic]wire.Session_Revision, context.temp_allocator)
}

create_on_ready :: proc(c: ^client.Client, result: wire.Initialize_Result) {
    o := (^Create_Obs)(c.user_data)

    // The snapshot borrows the frame arena, which this callback outlives.
    snapshot := make([]wire.Workspace, len(result.workspaces), context.temp_allocator)
    for workspace, i in result.workspaces {
        snapshot[i] = wire.Workspace {
            id    = workspace.id,
            root  = strings.clone(workspace.root, context.temp_allocator),
            title = strings.clone(workspace.title, context.temp_allocator),
        }
    }

    o.workspaces = snapshot

    create_send_next(c, o)
}

// Requests are serialized rather than pipelined: the second create in a workspace must
// observe what the first one registered.
create_send_next :: proc(c: ^client.Client, o: ^Create_Obs) {
    if o.sent == len(o.requests) {
        o.settled = true
        return
    }

    params := o.requests[o.sent]
    o.sent += 1
    client.client_send_request(c, .Session_Create, params, create_on_response)
}

create_on_response :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    o := (^Create_Obs)(c.user_data)
    answered, has_response := outcome.(client.Request_Response)
    if !has_response {
        o.settled = true
        return
    }

    switch resp in answered.response {
    case wire.Response_Ok:
        o.is_error = false

        if created, ok := resp.result.(wire.Session_Result); ok {
            append(&o.created, wire.session_clone(created.session, context.temp_allocator))
        }

    case wire.Response_Error:
        o.is_error = true
        o.code = resp.error.code
    }

    create_send_next(c, o)
}

create_on_broadcast :: proc(c: ^client.Client, bc: wire.Notification) {
    o := (^Create_Obs)(c.user_data)
    append(&o.names, bc.method)

    if summary, ok := bc.params.(wire.Session_Summary_Changed_Data); ok {
        append(&o.revisions, summary.revision)
    }
}

create_on_close :: proc(c: ^client.Client, _: client.Close_Code) {
    o := (^Create_Obs)(c.user_data)
    o.done = true
}

create_on_error :: proc(c: ^client.Client, _: client.Protocol_Error) {
    o := (^Create_Obs)(c.user_data)
    o.settled = true
    o.done = true
}

create_callbacks :: proc() -> client.Client_Callbacks {
    return client.Client_Callbacks {
        on_ready = create_on_ready,
        on_broadcast = create_on_broadcast,
        on_close = create_on_close,
        on_error = create_on_error,
    }
}

// Open one driver against `port` and run the loop until every request is answered.
create_client_run :: proc(
    t: ^testing.T,
    c: ^client.Client,
    loop: ^nbio.Event_Loop,
    port: int,
    o: ^Create_Obs,
    name := "yuke-test",
    version := "0.1.0",
) {
    transport, terr := client.ws_create(loop, {host = "127.0.0.1", port = port, path = "/ws"}, context.temp_allocator)
    testing.expect_value(t, terr, ws.Client_Error.None)

    cerr := client.client_open(c, transport, name, version, create_callbacks(), o, context.temp_allocator)
    testing.expect_value(t, cerr, client.Protocol_Error.None)
    testing.expect(t, pump_tick_until(&o.settled), "every session.create should be answered")
    pump_settle()
}

// A fresh session takes every documented default, its workspace is announced before the
// session that caused it, and the second session in that workspace re-announces nothing.
@(test)
test_session_create_registers_its_workspace_once :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "session-create")
    defer testsupport.sqlite_db_remove(path)

    root, root_err := os.get_absolute_path(".", context.temp_allocator)
    testing.expect_value(t, root_err, nil)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)

    requests := [?]wire.Create_Session {
        {workspace_path = "."},
        {
            workspace_path = ".",
            model = "test/model",
            reasoning = "high",
            profile = "review",
            permission = .Yolo,
            max_rounds = wire.Max_Rounds_Set{value = 7},
            system_prompt = wire.System_Prompt_Set{value = "be brief"},
        },
    }
    obs: Create_Obs
    create_obs_init(&obs, requests[:])

    c: client.Client
    create_client_run(t, &c, loop, bound_port(&d), &obs)

    if !testing.expect_value(t, len(obs.created), 2) {
        client.client_destroy(&c)
        test_teardown(&d)
        return
    }

    first := obs.created[0]
    testing.expect_value(t, first.workspace_id, workspace_id(root))
    testing.expect_value(t, first.profile, "default")
    testing.expect_value(t, first.model, "")
    testing.expect_value(t, first.reasoning, "")
    testing.expect_value(t, first.permission, wire.Permission_Mode.Normal)
    testing.expect_value(t, first.title, "")
    testing.expect_value(t, first.message_count, u64(0))
    testing.expect_value(t, first.config_rev, wire.Config_Rev(0))
    testing.expect(t, first.created_at_ms > 0, "a created session is stamped with the wall clock")
    testing.expect_value(t, first.updated_at_ms, first.created_at_ms)
    _, is_root := first.origin.(wire.Session_Origin_Root)
    testing.expect(t, is_root, "a session.create session is a root session")

    // A root session carries its creator; the wire refuses one that does not.
    creator, has_creator := first.created_by.?
    testing.expect(t, has_creator, "a root session names the client that created it")
    testing.expect_value(t, creator.name, "yuke-test")

    // Every override the request carried lands in the summary; `max_rounds` reaches it
    // only from the `set` arm, since omitted and explicit-null are both "no cap".
    second := obs.created[1]
    testing.expect(t, second.id != first.id, "each create mints its own id")
    testing.expect_value(t, second.workspace_id, first.workspace_id)
    testing.expect_value(t, second.model, "test/model")
    testing.expect_value(t, second.reasoning, "high")
    testing.expect_value(t, second.profile, "review")
    testing.expect_value(t, second.permission, wire.Permission_Mode.Yolo)
    cap, capped := second.max_rounds.?
    testing.expect(t, capped, "an explicit round cap reaches the summary")
    testing.expect_value(t, cap, u64(7))

    // An omitted cap is unlimited rather than zero.
    _, first_capped := first.max_rounds.?
    testing.expect(t, !first_capped, "an omitted round cap leaves the session uncapped")

    // `workspace.created` must precede the `session.summary_changed` it explains, and the
    // second session in the same directory finds the workspace already known.
    if testing.expect_value(t, len(obs.names), 3) {
        testing.expect_value(t, obs.names[0], wire.Broadcast_Name.Workspace_Created)
        testing.expect_value(t, obs.names[1], wire.Broadcast_Name.Session_Summary_Changed)
        testing.expect_value(t, obs.names[2], wire.Broadcast_Name.Session_Summary_Changed)
    }

    // The index revision is minted from 1, since the wire reserves 0 for a daemon that
    // has announced nothing.
    if testing.expect_value(t, len(obs.revisions), 2) {
        testing.expect_value(t, obs.revisions[0], wire.Session_Revision(1))
        testing.expect_value(t, obs.revisions[1], wire.Session_Revision(2))
    }

    // The connection opened before anything existed, so its snapshot was empty; the
    // registry is what a later connection reads back.
    testing.expect_value(t, len(obs.workspaces), 0)

    later: Create_Obs
    create_obs_init(&later, {})
    later_client: client.Client
    create_client_run(t, &later_client, loop, bound_port(&d), &later)

    if testing.expect_value(t, len(later.workspaces), 1) {
        testing.expect_value(t, later.workspaces[0].id, first.workspace_id)
        testing.expect_value(t, later.workspaces[0].root, root)
        testing.expect_value(t, later.workspaces[0].title, workspace_title(root))
    }

    client.client_close(&later_client)
    testing.expect(t, pump_tick_until(&later.done), "the second client should close cleanly")
    client.client_destroy(&later_client)

    client.client_close(&c)
    testing.expect(t, pump_tick_until(&obs.done), "the client should close cleanly")
    client.client_destroy(&c)
    test_teardown(&d)
}

// A path that does not resolve to a directory is a bad request, not a created session.
@(test)
test_session_create_refuses_a_path_that_is_not_a_directory :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "session-create-bad-path")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)

    requests := [?]wire.Create_Session{{workspace_path = "./no/such/directory"}}
    obs: Create_Obs
    create_obs_init(&obs, requests[:])

    c: client.Client
    create_client_run(t, &c, loop, bound_port(&d), &obs)

    testing.expect(t, obs.is_error, "an unresolvable path is refused")
    testing.expect_value(t, obs.code, wire.Error_Code.Bad_Request)
    testing.expect_value(t, len(obs.created), 0)
    testing.expect_value(t, len(obs.names), 0)

    client.client_close(&c)
    testing.expect(t, pump_tick_until(&obs.done), "the client should close cleanly")
    client.client_destroy(&c)
    test_teardown(&d)
}

// An empty client name is legal wire data — `client_validate` only bounds its length — so
// it must reach the summary as an empty creator rather than tripping an assertion. This is
// peer-controlled input: a crash here would be a remote kill switch.
@(test)
test_session_create_accepts_an_unnamed_client :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "session-create-unnamed")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)

    requests := [?]wire.Create_Session{{workspace_path = "."}}
    obs: Create_Obs
    create_obs_init(&obs, requests[:])

    c: client.Client
    create_client_run(t, &c, loop, bound_port(&d), &obs, name = "", version = "")

    if testing.expect_value(t, len(obs.created), 1) {
        creator, has_creator := obs.created[0].created_by.?
        testing.expect(t, has_creator, "a root session still names its creator")
        testing.expect_value(t, creator.name, "")
    }

    client.client_close(&c)
    testing.expect(t, pump_tick_until(&obs.done), "the client should close cleanly")
    client.client_destroy(&c)
    test_teardown(&d)
}
