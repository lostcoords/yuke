package daemon

import "core:nbio"
import "core:os"
import "core:strings"
import "core:testing"

import "libs:testsupport"
import ws "libs:websocket"

import "src:client"
import "src:daemon/store"
import "src:wire"

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

// `run_handler` on a daemon holding a seeded file registry.
@(private = "file")
run_session_list :: proc(t: ^testing.T, name: string, obs: ^Handler_Obs, sessions: ..wire.Session) {
    path := testsupport.sqlite_db_path(t, name)
    defer testsupport.sqlite_db_remove(path)

    run_handler(t, obs, path, ..sessions)
}

// A registry row differing only in what `session.list` orders and displays.
@(private = "file")
listed_session :: proc(tag: u8, updated_at_ms: u64, title: string) -> wire.Session {
    session := daemon_test_session(pump_test_session(tag))
    session.updated_at_ms = updated_at_ms
    session.title = title

    return session
}

@(private = "file")
list_result :: proc(t: ^testing.T, resp: wire.Response) -> (wire.Session_List_Result, bool) {
    ok, is_ok := resp.(wire.Response_Ok)

    if !testing.expect(t, is_ok, "session.list should answer with a result") {
        return {}, false
    }

    result, is_list := ok.result.(wire.Session_List_Result)
    testing.expect(t, is_list, "session.list should answer with a session list")

    return result, is_list
}

// The handshake this whole slice is for: a client asks, and the rows the daemon persisted
// come back — not an empty page.
@(test)
test_session_list_returns_persisted_sessions :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    check :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
        result, ok := list_result(o.t, resp)
        if !ok {
            return true
        }

        testing.expect_value(o.t, result.total, u64(2))
        testing.expect_value(o.t, len(result.items), 2)

        if len(result.items) == 2 {
            // Newest first, so the later `updated_at_ms` leads.
            testing.expect_value(o.t, result.items[0].session.title, "newer")
            testing.expect_value(o.t, result.items[1].session.title, "older")

            // No engine means no run, so every row reads back idle.
            _, idle := result.items[0].activity.state.(wire.Activity_State_Idle)
            testing.expect(o.t, idle, "a listed session with no engine is idle")
        }

        // A daemon that has just started has changed its own index zero times.
        testing.expect_value(o.t, result.revision, wire.Session_Revision(0))

        _, paging := result.next_cursor.?
        testing.expect(o.t, !paging, "a page that exhausted the view mints no continuation")

        return true
    }

    obs := Handler_Obs {
        method = .Session_List,
        params = wire.Session_List_Params {
            scope = wire.Session_Scope_All{},
            population = wire.Session_Population_All{},
            view = .Active_Recent,
        },
        check = check,
    }

    run_session_list(t, "list-basic", &obs, listed_session('a', 10, "older"), listed_session('b', 20, "newer"))
}

// A bounded page mints a continuation, and following it reaches the rest of the view
// exactly once.
@(test)
test_session_list_pages_through_a_cursor :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    check :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
        result, ok := list_result(o.t, resp)
        if !ok {
            return true
        }

        // `total` describes the whole view on every page, not the page in hand.
        testing.expect_value(o.t, result.total, u64(3))
        testing.expect_value(o.t, len(result.items), 1)

        if o.page == 0 {
            testing.expect_value(o.t, result.items[0].session.title, "third")

            cursor, paging := result.next_cursor.?
            if !testing.expect(o.t, paging, "a page with rows behind it mints a continuation") {
                return true
            }

            o.page = 1

            // The cursor borrows this callback's frame; `client_send_request` copies it
            // into the outbound frame synchronously.
            client.client_send_request(
                c,
                .Session_List,
                wire.Session_List_Params {
                    scope = wire.Session_Scope_All{},
                    population = wire.Session_Population_All{},
                    view = .Active_Recent,
                    limit = 1,
                    cursor = cursor,
                },
                handler_on_response,
            )

            return false
        }

        // The second page resumed strictly below the first rather than repeating it.
        testing.expect_value(o.t, result.items[0].session.title, "second")

        return true
    }

    obs := Handler_Obs {
        method = .Session_List,
        params = wire.Session_List_Params {
            scope = wire.Session_Scope_All{},
            population = wire.Session_Population_All{},
            view = .Active_Recent,
            limit = 1,
        },
        check = check,
    }

    run_session_list(
        t,
        "list-cursor",
        &obs,
        listed_session('a', 10, "first"),
        listed_session('b', 20, "second"),
        listed_session('c', 30, "third"),
    )
}

// A cursor is a position in one selection. Replaying it against a different one must fail
// loudly rather than page through a set it was never a position in.
@(test)
test_session_list_refuses_a_cursor_from_another_selection :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    check :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
        if o.page == 0 {
            result, ok := list_result(o.t, resp)
            if !ok {
                return true
            }

            cursor, paging := result.next_cursor.?
            if !testing.expect(o.t, paging, "the first page mints a continuation") {
                return true
            }

            o.page = 1

            // Same cursor, narrower population: the token names a selection this request
            // is not making.
            client.client_send_request(
                c,
                .Session_List,
                wire.Session_List_Params {
                    scope = wire.Session_Scope_All{},
                    population = wire.Session_Population_Top_Level{},
                    view = .Active_Recent,
                    limit = 1,
                    cursor = cursor,
                },
                handler_on_response,
            )

            return false
        }

        failure, is_error := resp.(wire.Response_Error)

        if testing.expect(o.t, is_error, "a cursor from another selection is refused") {
            testing.expect_value(o.t, failure.error.code, wire.Error_Code.Bad_Request)
        }

        return true
    }

    obs := Handler_Obs {
        method = .Session_List,
        params = wire.Session_List_Params {
            scope = wire.Session_Scope_All{},
            population = wire.Session_Population_All{},
            view = .Active_Recent,
            limit = 1,
        },
        check = check,
    }

    run_session_list(
        t,
        "list-cursor-mismatch",
        &obs,
        listed_session('a', 10, "first"),
        listed_session('b', 20, "second"),
    )
}

// A malformed cursor is peer input: it is answered, not asserted on and not closed over.
@(test)
test_session_list_rejects_a_malformed_cursor :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    check :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
        failure, is_error := resp.(wire.Response_Error)

        if testing.expect(o.t, is_error, "a malformed cursor is refused") {
            testing.expect_value(o.t, failure.error.code, wire.Error_Code.Bad_Request)
        }

        return true
    }

    obs := Handler_Obs {
        method = .Session_List,
        params = wire.Session_List_Params {
            scope = wire.Session_Scope_All{},
            population = wire.Session_Population_All{},
            view = .Active_Recent,
            cursor = "not-a-cursor",
        },
        check = check,
    }

    run_session_list(t, "list-bad-cursor", &obs, listed_session('a', 10, "only"))
}

// `active` selects a different population from the registry: a persisted session the engine
// holds nothing for is not active, and one it does hold appears with no page read at all.
@(test)
test_session_list_active_view_follows_the_engine :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    check :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
        result, ok := list_result(o.t, resp)
        if !ok {
            return true
        }

        // First answer: the registry row exists, but nothing tracks it.
        if o.page == 0 {
            testing.expect_value(o.t, len(result.items), 0)
            testing.expect_value(o.t, result.total, u64(0))

            o.page = 1
            testing.expect(
                o.t,
                session_live_ensure(o.daemon, pump_test_session('a')) != nil,
                "the engine takes the session",
            )
            client.client_send_request(c, .Session_List, o.params, handler_on_response)

            return false
        }

        // Second answer: the same registry, one tracked session.
        if testing.expect_value(o.t, len(result.items), 1) {
            testing.expect_value(o.t, result.items[0].session.title, "idle")
        }

        testing.expect_value(o.t, result.total, u64(1))

        return true
    }

    obs := Handler_Obs {
        method = .Session_List,
        params = wire.Session_List_Params {
            scope = wire.Session_Scope_All{},
            population = wire.Session_Population_All{},
            view = .Active,
        },
        check = check,
    }

    run_session_list(t, "list-active", &obs, listed_session('a', 10, "idle"))
}

// The active view pages on the registry's keyset and cursor grammar, so a continuation is
// minted exactly when rows remain and a null one really does end the selection.
@(test)
test_session_list_active_view_pages_through_a_cursor :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    check :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
        result, ok := list_result(o.t, resp)
        if !ok {
            return true
        }

        // First answer: both rows are persisted, but the engine tracks neither.
        if o.page == 0 {
            testing.expect_value(o.t, len(result.items), 0)
            testing.expect_value(o.t, result.total, u64(0))

            o.page = 1
            for tag in ([?]u8{'a', 'b'}) {
                testing.expect(
                    o.t,
                    session_live_ensure(o.daemon, pump_test_session(tag)) != nil,
                    "the engine takes the session",
                )
            }
            client.client_send_request(c, .Session_List, o.params, handler_on_response)

            return false
        }

        // `total` describes the whole selection on every page, as it does for the registry.
        testing.expect_value(o.t, result.total, u64(2))
        testing.expect_value(o.t, len(result.items), 1)

        if o.page == 1 {
            testing.expect_value(o.t, result.items[0].session.title, "newer")

            cursor, paging := result.next_cursor.?
            if !testing.expect(o.t, paging, "a page with a row behind it mints a continuation") {
                return true
            }

            o.page = 2
            client.client_send_request(
                c,
                .Session_List,
                wire.Session_List_Params {
                    scope = wire.Session_Scope_All{},
                    population = wire.Session_Population_All{},
                    view = .Active,
                    limit = 1,
                    cursor = cursor,
                },
                handler_on_response,
            )

            return false
        }

        // The second page resumed strictly below the first rather than repeating it.
        testing.expect_value(o.t, result.items[0].session.title, "older")
        _, more := result.next_cursor.?
        testing.expect(o.t, !more, "the last page mints no continuation")

        return true
    }

    obs := Handler_Obs {
        method = .Session_List,
        params = wire.Session_List_Params {
            scope = wire.Session_Scope_All{},
            population = wire.Session_Population_All{},
            view = .Active,
            limit = 1,
        },
        check = check,
    }

    run_session_list(t, "list-active-cursor", &obs, listed_session('a', 10, "older"), listed_session('b', 20, "newer"))
}

// One driver that subscribes to a session and then sends inputs into it. `input.queued`
// and `message.committed` are subscription-gated; every broadcast is also folded into a
// replica, so the announced pair is checked against the client model that consumes it.
Input_Obs :: struct {
    // Session to subscribe to and address.
    session:        wire.Session_Id,

    // Inputs to send, one after the previous is answered.
    inputs:         []wire.Input,
    sent:           int,

    // Input ids answered, in request order; short when a send answered with an error.
    accepted:       [dynamic]wire.Input_Id,

    // Run ids answered, for the sends that started a turn.
    runs:           [dynamic]wire.Run_Id,

    // Error code of the last answered request; `is_error` says whether it means anything.
    is_error:       bool,
    code:           wire.Error_Code,

    // Broadcast names delivered, in arrival order, with the payloads worth reading back
    // cloned out of the frame arena they borrow.
    names:          [dynamic]wire.Broadcast_Name,

    // Arrival wall clock per broadcast, parallel to `names`, for proving that a stream is
    // delivered as it arrives rather than in one flush at the end.
    times:          [dynamic]u64,

    // Activity states delivered, in arrival order, so a test can assert the phases a turn
    // moved through rather than only that it announced something.
    activities:     [dynamic]wire.Session_Activity,
    queued:         [dynamic]wire.Queued_Input,
    committed:      [dynamic]wire.User_Message,
    assistants:     [dynamic]wire.Assistant_Message,
    turns:          [dynamic]wire.Run_Outcome_Turn,
    failures:       [dynamic]wire.Run_Error_Code,
    canceled_runs:  int,
    summaries:      [dynamic]wire.Session,

    // A `run.done` arrived, so the turn this driver started has finished.
    turn_done:      bool,

    // Issue one `session.cancel_run` once every input is answered, optionally naming a
    // run, and keep what it answered. `cancel_input` names a queued input instead.
    cancel_input:   Maybe(wire.Input_Id),
    cancel:         bool,
    cancel_run:     Maybe(wire.Run_Id),
    cancel_sent:    bool,
    canceled:       wire.Session_Cancel_Run_Result,
    canceled_input: wire.Input_Id,

    // The replica every broadcast is folded into, and the first refusal it reported.
    replica:        client.Session_Replica,
    apply_err:      client.Replica_Error,

    // Every request has been answered.
    settled:        bool,

    // Terminal callback fired.
    done:           bool,
}

input_obs_init :: proc(o: ^Input_Obs, session: wire.Session_Id, inputs: []wire.Input) {
    o.session = session
    o.inputs = inputs
    o.accepted = make([dynamic]wire.Input_Id, context.temp_allocator)
    o.runs = make([dynamic]wire.Run_Id, context.temp_allocator)
    o.names = make([dynamic]wire.Broadcast_Name, context.temp_allocator)
    o.times = make([dynamic]u64, context.temp_allocator)
    o.activities = make([dynamic]wire.Session_Activity, context.temp_allocator)
    o.queued = make([dynamic]wire.Queued_Input, context.temp_allocator)
    o.committed = make([dynamic]wire.User_Message, context.temp_allocator)
    o.assistants = make([dynamic]wire.Assistant_Message, context.temp_allocator)
    o.turns = make([dynamic]wire.Run_Outcome_Turn, context.temp_allocator)
    o.failures = make([dynamic]wire.Run_Error_Code, context.temp_allocator)
    o.summaries = make([dynamic]wire.Session, context.temp_allocator)
    client.replica_init(&o.replica, context.allocator, session)
}

input_on_ready :: proc(c: ^client.Client, _: wire.Initialize_Result) {
    o := (^Input_Obs)(c.user_data)

    client.client_send_request(
        c,
        .Subscription_Set,
        wire.Subscription_Set_Params{sessions = {o.session}},
        input_on_sub,
    )
}

input_on_sub :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    o := (^Input_Obs)(c.user_data)
    answered, has_response := outcome.(client.Request_Response)
    if !has_response {
        o.settled = true
        return
    }

    if _, ok := answered.response.(wire.Response_Ok); !ok {
        o.settled = true
        return
    }

    input_send_next(c, o)
}

// Requests are serialized rather than pipelined: the second input must observe the id
// marks the first one raised.
input_send_next :: proc(c: ^client.Client, o: ^Input_Obs) {
    if o.sent == len(o.inputs) {
        if input_id, cancels_input := o.cancel_input.?; cancels_input && !o.cancel_sent {
            o.cancel_sent = true
            client.client_send_request(
                c,
                .Session_Cancel_Input,
                wire.Session_Cancel_Input_Params{session_id = o.session, input_id = input_id},
                input_on_cancel,
            )

            return
        }

        if o.cancel && !o.cancel_sent {
            o.cancel_sent = true
            client.client_send_request(
                c,
                .Session_Cancel_Run,
                wire.Session_Cancel_Run_Params{session_id = o.session, run_id = o.cancel_run},
                input_on_cancel,
            )

            return
        }

        o.settled = true
        return
    }

    input := o.inputs[o.sent]
    o.sent += 1
    client.client_send_request(
        c,
        .Session_Send_Input,
        wire.Session_Send_Input_Params{session_id = o.session, input = input},
        input_on_response,
    )
}

input_on_response :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    o := (^Input_Obs)(c.user_data)
    answered, has_response := outcome.(client.Request_Response)
    if !has_response {
        o.settled = true
        return
    }

    switch resp in answered.response {
    case wire.Response_Ok:
        o.is_error = false

        if result, ok := resp.result.(wire.Session_Send_Input_Result); ok {
            switch answer in result {
            case wire.Session_Send_Input_Result_Started:
                append(&o.accepted, answer.input_id)
                append(&o.runs, answer.run_id)

            case wire.Session_Send_Input_Result_Queued:
                append(&o.accepted, answer.input_id)
            }
        }

    case wire.Response_Error:
        o.is_error = true
        o.code = resp.error.code
    }

    input_send_next(c, o)
}

// The cancel is the driver's last request, so its answer settles the run.
input_on_cancel :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    o := (^Input_Obs)(c.user_data)
    o.settled = true

    answered, has_response := outcome.(client.Request_Response)
    if !has_response {
        return
    }

    switch resp in answered.response {
    case wire.Response_Ok:
        o.is_error = false

        if result, ok := resp.result.(wire.Session_Cancel_Run_Result); ok {
            o.canceled = result
        }

        if result, ok := resp.result.(wire.Session_Cancel_Input_Result); ok {
            o.canceled_input = result.canceled_input
        }

    case wire.Response_Error:
        o.is_error = true
        o.code = resp.error.code
    }
}

input_on_broadcast :: proc(c: ^client.Client, bc: wire.Notification) {
    o := (^Input_Obs)(c.user_data)
    append(&o.names, bc.method)
    append(&o.times, now_ms())

    #partial switch v in bc.params {
    case wire.Input_Queued_Data:
        append(&o.queued, wire.queued_input_clone(v.input, context.temp_allocator))

    case wire.Message_Committed_Data:
        switch message in v.message {
        case wire.User_Message:
            append(&o.committed, wire.user_message_clone(message, context.temp_allocator))

        case wire.Assistant_Message:
            append(&o.assistants, wire.assistant_message_clone(message, context.temp_allocator))

        case wire.Compaction_Message:
        }

    case wire.Session_Activity_Changed_Data:
        activity := v.activity
        activity.state = wire.activity_state_clone(v.activity.state, context.temp_allocator)
        append(&o.activities, activity)

    case wire.Run_Done_Data:
        o.turn_done = true

        switch outcome in v.outcome {
        case wire.Run_Outcome_Turn:
            turn := outcome
            append(&o.turns, turn)

        case wire.Run_Outcome_Failed:
            append(&o.failures, outcome.code)

        case wire.Run_Outcome_Canceled:
            o.canceled_runs += 1

        case wire.Run_Outcome_Compacted, wire.Run_Outcome_Skipped:
        }

    case wire.Session_Summary_Changed_Data:
        append(&o.summaries, wire.session_clone(v.session, context.temp_allocator))
    }

    if _, err := client.replica_apply_broadcast(&o.replica, bc); err != .None && o.apply_err == .None {
        o.apply_err = err
    }
}

input_on_close :: proc(c: ^client.Client, _: client.Close_Code) {
    o := (^Input_Obs)(c.user_data)
    o.done = true
}

input_on_error :: proc(c: ^client.Client, _: client.Protocol_Error) {
    o := (^Input_Obs)(c.user_data)
    o.settled = true
    o.done = true
}

input_callbacks :: proc() -> client.Client_Callbacks {
    return client.Client_Callbacks {
        on_ready = input_on_ready,
        on_broadcast = input_on_broadcast,
        on_close = input_on_close,
        on_error = input_on_error,
    }
}

// Open one driver against `port` and run the loop until every input is answered.
input_client_run :: proc(t: ^testing.T, c: ^client.Client, loop: ^nbio.Event_Loop, port: int, o: ^Input_Obs) {
    transport, terr := client.ws_create(loop, {host = "127.0.0.1", port = port, path = "/ws"}, context.temp_allocator)
    testing.expect_value(t, terr, ws.Client_Error.None)

    cerr := client.client_open(c, transport, "yuke-test", "0.1.0", input_callbacks(), o, context.temp_allocator)
    testing.expect_value(t, cerr, client.Protocol_Error.None)
    testing.expect(t, pump_tick_until(&o.settled), "every session.send_input should be answered")
    pump_settle()
}

// Close the driver and tear the daemon down; every exit path runs the same teardown.
input_client_stop :: proc(t: ^testing.T, c: ^client.Client, d: ^Daemon, o: ^Input_Obs) {
    client.client_close(c)
    testing.expect(t, pump_tick_until(&o.done), "the client should close cleanly")
    client.client_destroy(c)
    client.replica_destroy(&o.replica)
    test_teardown(d)
}

// The accepted input is announced live and then committed durably, in that order, and the
// two name the same id. Ids start at 1, increment across sends, and land in the store's
// marks without a write of their own.
@(test)
test_session_send_input_commits_the_user_message :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "session-send-input")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    session := pump_test_session('a')

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    daemon_test_session_create(t, &d, session)

    first := [?]wire.Content_Part{wire.Content_Text{text = "first"}}
    second := [?]wire.Content_Part{wire.Content_Text{text = "second"}}
    inputs := [?]wire.Input{wire.Input_Content{content = first[:]}, wire.Input_Content{content = second[:]}}

    obs: Input_Obs
    input_obs_init(&obs, session, inputs[:])

    c: client.Client
    input_client_run(t, &c, loop, bound_port(&d), &obs)

    // The fixture's model is in no catalog, so no turn starts. The input is durable
    // either way: a refused turn does not undo the message the user already sent.
    testing.expect(t, obs.is_error, "a session whose model resolves to nothing starts no turn")
    testing.expect_value(t, obs.code, wire.Error_Code.Unsupported_Model)
    testing.expect_value(t, len(obs.runs), 0)

    // `input.queued` precedes the commit it explains, and the index is refreshed after
    // the commit that moved it.
    if testing.expect_value(t, len(obs.names), 6) {
        testing.expect_value(t, obs.names[0], wire.Broadcast_Name.Input_Queued)
        testing.expect_value(t, obs.names[1], wire.Broadcast_Name.Message_Committed)
        testing.expect_value(t, obs.names[2], wire.Broadcast_Name.Session_Summary_Changed)
        testing.expect_value(t, obs.names[3], wire.Broadcast_Name.Input_Queued)
        testing.expect_value(t, obs.names[4], wire.Broadcast_Name.Message_Committed)
        testing.expect_value(t, obs.names[5], wire.Broadcast_Name.Session_Summary_Changed)
    }

    if testing.expect_value(t, len(obs.queued), 2) && testing.expect_value(t, len(obs.committed), 2) {
        testing.expect_value(t, obs.queued[0].input_id, obs.committed[0].input_id)
        testing.expect_value(t, obs.queued[1].input_id, obs.committed[1].input_id)
        testing.expect_value(t, obs.committed[0].id, wire.Message_Id(1))
        testing.expect_value(t, obs.committed[1].id, wire.Message_Id(2))
        testing.expect(t, obs.queued[0].queued_at_ms > 0, "a queued input is stamped with the wall clock")

        // The content the request carried reaches the transcript unchanged.
        if testing.expect_value(t, len(obs.committed[0].content), 1) {
            text, is_text := obs.committed[0].content[0].(wire.Content_Text)
            testing.expect(t, is_text, "a text part commits as a text part")
            testing.expect_value(t, text.text, "first")
        }

        // The commit stamps both timestamps from one clock read, so the summary the
        // index carries cannot disagree with the message that moved it.
        testing.expect_value(t, obs.committed[0].time.created_at_ms, obs.queued[0].queued_at_ms)
    }

    // The index the commit moved: `session.list` orders on `updated_at_ms`, which the
    // fixture left at 1.
    if testing.expect_value(t, len(obs.summaries), 2) {
        testing.expect_value(t, obs.summaries[0].message_count, u64(1))
        testing.expect_value(t, obs.summaries[1].message_count, u64(2))
        testing.expect(t, obs.summaries[1].updated_at_ms > 1, "committing a message moves the update mark")
    }

    // Both id families advanced in the append's own transaction.
    hw, herr := store.high_water(d.store, session)
    testing.expect_value(t, herr, nil)
    testing.expect_value(t, hw.seq, wire.Seq(2))
    testing.expect_value(t, hw.message_id, wire.Message_Id(2))
    testing.expect_value(t, hw.input_id, wire.Input_Id(2))

    // The pair converges: the commit dequeues the input it names, so a replica fed both
    // broadcasts holds the messages and nothing else.
    testing.expect_value(t, obs.apply_err, client.Replica_Error.None)
    testing.expect_value(t, len(obs.replica.queued), 0)
    testing.expect_value(t, len(obs.replica.messages), 2)

    input_client_stop(t, &c, &d, &obs)
}

// A send into a session that was never created is refused before anything is announced.
@(test)
test_session_send_input_refuses_an_unknown_session :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "session-send-input-unknown")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    daemon_test_session_create(t, &d, pump_test_session('a'))

    parts := [?]wire.Content_Part{wire.Content_Text{text = "hello"}}
    inputs := [?]wire.Input{wire.Input_Content{content = parts[:]}}

    // Never created, so the registry has no row for the session the send names. The
    // subscription takes the id as given, so a refusal would still have been observed.
    obs: Input_Obs
    input_obs_init(&obs, pump_test_session('b'), inputs[:])

    c: client.Client
    input_client_run(t, &c, loop, bound_port(&d), &obs)

    testing.expect(t, obs.is_error, "an unknown session is refused")
    testing.expect_value(t, obs.code, wire.Error_Code.Unknown_Session)
    testing.expect_value(t, len(obs.accepted), 0)
    testing.expect_value(t, len(obs.names), 0)

    input_client_stop(t, &c, &d, &obs)
}

// A commit that never lands retracts the input it already announced. `input.queued` is
// live-only, so nothing in the log or a later resync takes it back: a subscriber that is
// not told the input is gone waits for it forever. The append refuses a session with no
// registry row, which is the failure the handler cannot rule out in advance.
@(test)
test_session_send_input_retracts_an_uncommittable_input :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "session-send-input-retract")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    // The refused append is logged as an error, which the runner would otherwise count as
    // a test failure; the assertions below are the check.
    saved_logger := context.logger
    quiet_logger: testsupport.Assert_Only_Logger
    context.logger = testsupport.assert_only_logger(&quiet_logger, saved_logger)
    defer context.logger = saved_logger

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)

    // Never created, so the append has no row to advance. `subscription.set` takes ids as
    // given, so a connection can still watch it.
    phantom := pump_test_session('c')

    obs: Input_Obs
    input_obs_init(&obs, phantom, {})

    c: client.Client
    input_client_run(t, &c, loop, bound_port(&d), &obs)

    parts := [?]wire.Content_Part{wire.Content_Text{text = "stranded"}}
    queued := wire.Queued_Input {
        input_id     = 1,
        content      = parts[:],
        queued_at_ms = 1,
    }
    committed := wire.User_Message {
        id = 1,
        content = parts[:],
        input_id = 1,
        time = wire.Created_Time{created_at_ms = 1},
    }

    published := send_input_publish(&d, phantom, queued, committed, context.temp_allocator)
    testing.expect(t, !published, "an append into a session with no registry row fails")
    pump_settle()

    if testing.expect_value(t, len(obs.names), 2) {
        testing.expect_value(t, obs.names[0], wire.Broadcast_Name.Input_Queued)
        testing.expect_value(t, obs.names[1], wire.Broadcast_Name.Input_Canceled)
    }

    // The replica took both broadcasts, and its queue drains rather than holding an input
    // no commit will ever name.
    testing.expect_value(t, obs.apply_err, client.Replica_Error.None)
    testing.expect_value(t, len(obs.replica.queued), 0)
    testing.expect_value(t, len(obs.replica.messages), 0)

    // The refused commit logged nothing durable either.
    hw, herr := store.high_water(d.store, phantom)
    testing.expect_value(t, herr, nil)
    testing.expect_value(t, hw.seq, wire.Seq(0))

    input_client_stop(t, &c, &d, &obs)
}

// A skill reaches the transcript as rendered content parts, and nothing renders one yet,
// so it is refused rather than committed empty.
@(test)
test_session_send_input_refuses_a_skill :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    path := testsupport.sqlite_db_path(t, "session-send-input-skill")
    defer testsupport.sqlite_db_remove(path)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    session := pump_test_session('a')

    d: Daemon
    testing.expect_value(t, start(&d, loop, {host = "127.0.0.1", port = 0, db_path = path}), Error.None)
    daemon_test_session_create(t, &d, session)

    inputs := [?]wire.Input{wire.Input_Skill{skill = wire.Skill_Ref{name = "review", arguments = "{}"}}}

    obs: Input_Obs
    input_obs_init(&obs, session, inputs[:])

    c: client.Client
    input_client_run(t, &c, loop, bound_port(&d), &obs)

    testing.expect(t, obs.is_error, "an unrenderable skill is refused")
    testing.expect_value(t, obs.code, wire.Error_Code.Unknown_Skill)
    testing.expect_value(t, len(obs.names), 0)

    input_client_stop(t, &c, &d, &obs)
}
