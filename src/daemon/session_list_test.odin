package daemon

import "core:testing"

import "libs:testsupport"
import "src:client"
import wire "src:wire"

// `run_handler` on a daemon holding a seeded registry, so what comes back is what SQLite
// holds rather than the empty page a storeless daemon can only ever answer.
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

// `active` selects sessions with a live run. With no engine there are none, so the empty
// page is the answer even though the registry holds rows.
@(test)
test_session_list_active_view_is_empty_without_an_engine :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    check :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
        result, ok := list_result(o.t, resp)
        if !ok {
            return true
        }

        testing.expect_value(o.t, len(result.items), 0)
        testing.expect_value(o.t, result.total, u64(0))

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
