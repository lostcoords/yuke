package daemon

import "core:log"
import "core:mem"
import "core:strconv"
import "core:strings"

import store "src:daemon/store"
import wire "src:wire"

// A `session.list` cursor is `<filter key>.<updated_at_ms>.<session id>`. The key ties a
// cursor to one selection, so replaying it against a different scope is `Bad_Request`.
@(private = "file")
CURSOR_SEPARATOR :: '.'

// `strconv.parse_u64` wraps silently and still reports success, so a longer run of digits
// is rejected before it is parsed rather than after.
@(private = "file")
MAX_CURSOR_TIMESTAMP_DIGITS :: 20

// A filter key is a scope arm and a population arm, each a tag byte plus at most one
// 16-character id.
@(private = "file")
MAX_FILTER_KEY_BYTES :: 2 * (1 + size_of(wire.Session_Id))

// The key, two separators, the timestamp, and the position's id.
@(private = "file")
MAX_CURSOR_BYTES :: MAX_FILTER_KEY_BYTES + 2 + MAX_CURSOR_TIMESTAMP_DIGITS + size_of(wire.Session_Id)

// The compact index revision every announcement and snapshot carries. Daemon-lifetime,
// so a client that reconnects sees it restart and refetches; minted from 1 because the
// wire reserves 0 for "this daemon has changed nothing yet".
session_revision_next :: proc(d: ^Daemon) -> wire.Session_Revision {
    assert(d != nil, "a session index revision needs daemon state")
    assert(u64(d.session_revision) < wire.MAX_SESSION_REVISION, "the session index revision is exhausted")

    d.session_revision += 1

    return d.session_revision
}

// `session.list` over the registry: page, continuation, and total read straight from
// SQLite, at the daemon's current index revision. Every session reads back idle
// (no session engine exists).
method_session_list :: proc(conn: ^Conn, req: wire.Request, sa: mem.Allocator) {
    assert(conn != nil, "session.list needs connection state")
    assert(conn.state == .Ready, "session.list ran outside Ready")
    assert(req.method == .Session_List, "session.list received another method")
    assert(conn.daemon != nil, "a connection always names its daemon")

    params := req.params.(wire.Session_List_Params)
    d := conn.daemon

    filter := store.Session_Filter {
        scope      = params.scope,
        population = params.population,
    }

    assert(d.store != nil, "a serving daemon always owns an event store")

    // `active` selects sessions with a live run; without an engine there are none, so an
    // empty page is correct — `recent` and `active_recent` coincide for the same reason.
    if params.view == .Active {
        send_result(conn, req.id, wire.Session_List_Result{}, sa)
        return
    }

    cursor: Maybe(store.Session_Cursor)
    if token, paging := params.cursor.?; paging {
        position, valid := session_cursor_decode(token, filter)

        if !valid {
            send_error(conn, req.id, .Bad_Request, "malformed session.list cursor", sa)
            return
        }

        cursor = position
    }

    // Already validated to be within bounds; default when omitted.
    limit := wire.LIMITS.default_session_list_page_size
    if requested, ok := params.limit.?; ok {
        limit = int(requested)
    }

    // One row past the page, so a continuation is minted only when a further row exists
    // rather than on every full page. The extra row is dropped before the result is built.
    sessions, page_err := store.session_page(d.store, filter, cursor, limit + 1, sa)
    if page_err != nil {
        log.errorf("daemon: session.list page read failed: %v", page_err)
        send_error(conn, req.id, .Internal, "session index unavailable", sa)

        return
    }

    more := len(sessions) > limit
    if more {
        sessions = sessions[:limit]
    }

    // A first page that wasn't truncated already holds the whole selection, so its length is
    // the total; only a paged or truncated view pays for the count, which is unbounded work.
    total := u64(len(sessions))
    if more || cursor != nil {
        counted, count_err := store.session_count(d.store, filter)

        if count_err != nil {
            log.errorf("daemon: session.list count failed: %v", count_err)
            send_error(conn, req.id, .Internal, "session index unavailable", sa)

            return
        }

        total = counted
    }

    items, items_err := make([]wire.Session_List_Item, len(sessions), sa)
    if items_err != nil {
        send_error(conn, req.id, .Internal, "session index unavailable", sa)
        return
    }

    for session, i in sessions {
        items[i] = wire.Session_List_Item {
            session = session,
            activity = {state = wire.Activity_State_Idle{}},
        }
    }

    result := wire.Session_List_Result {
        revision = d.session_revision,
        items    = items,
        total    = total,
    }

    if more {
        last := sessions[len(sessions) - 1]
        result.next_cursor = session_cursor_encode(filter, {updated_at_ms = last.updated_at_ms, id = last.id}, sa)
    }

    // Every remaining field is daemon-built and the store already refused any row the protocol
    // would reject, so `send_result`'s validation assertion covers the rest.
    send_result(conn, req.id, result, sa)
}

// Write the selection a cursor belongs to. Every arm contributes a distinct leading byte, and
// ids are already 16 lowercase hex characters, so no arm's encoding can prefix another's.
@(private = "file")
session_filter_key_write :: proc(b: ^strings.Builder, filter: store.Session_Filter) {
    assert(filter.scope != nil, "a session filter carries its scope")
    assert(filter.population != nil, "a session filter carries its population")

    switch scope in filter.scope {
    case wire.Session_Scope_All:
        strings.write_byte(b, 'a')

    case wire.Session_Scope_Workspace:
        strings.write_byte(b, 'w')
        id := ([16]u8)(scope.workspace_id)
        strings.write_bytes(b, id[:])
    }

    switch population in filter.population {
    case wire.Session_Population_Top_Level:
        strings.write_byte(b, 't')

    case wire.Session_Population_All:
        strings.write_byte(b, 'e')

    case wire.Session_Population_Children:
        strings.write_byte(b, 'c')
        id := ([16]u8)(population.parent_id)
        strings.write_bytes(b, id[:])

    case wire.Session_Population_Job_Runs:
        strings.write_byte(b, 'j')
        id := ([16]u8)(population.job_id)
        strings.write_bytes(b, id[:])
    }
}

// Mint the continuation for `position` under `filter`, sized exactly for a filter key plus
// a timestamp and id — well inside the protocol's cursor bound.
@(private = "file")
session_cursor_encode :: proc(
    filter: store.Session_Filter,
    position: store.Session_Cursor,
    allocator: mem.Allocator,
) -> string {
    b := strings.builder_make(0, MAX_CURSOR_BYTES, allocator) or_else strings.Builder{}

    session_filter_key_write(&b, filter)
    strings.write_byte(&b, CURSOR_SEPARATOR)
    strings.write_u64(&b, position.updated_at_ms)
    strings.write_byte(&b, CURSOR_SEPARATOR)

    id := ([16]u8)(position.id)
    strings.write_bytes(&b, id[:])

    token := strings.to_string(b)
    assert(len(token) <= wire.LIMITS.max_session_list_cursor_bytes, "a minted cursor fits the protocol bound")

    return token
}

// Read a continuation back, refusing one minted for any other selection. The whole token
// is peer input: nothing here asserts on its contents.
@(private = "file")
session_cursor_decode :: proc(
    token: string,
    filter: store.Session_Filter,
) -> (
    position: store.Session_Cursor,
    ok: bool,
) {
    key_buf: [MAX_FILTER_KEY_BYTES]u8
    b := strings.builder_from_bytes(key_buf[:])
    session_filter_key_write(&b, filter)
    key := strings.to_string(b)

    // The cursor names the selection it is a position in; anything else is a token this
    // request has no meaning for.
    if len(token) <= len(key) || token[:len(key)] != key || token[len(key)] != CURSOR_SEPARATOR {
        return {}, false
    }

    rest := token[len(key) + 1:]
    split := strings.index_byte(rest, CURSOR_SEPARATOR)

    if split < 0 {
        return {}, false
    }

    digits := rest[:split]
    id := rest[split + 1:]

    if len(digits) == 0 || len(digits) > MAX_CURSOR_TIMESTAMP_DIGITS {
        return {}, false
    }

    updated_at_ms, parsed := strconv.parse_u64(digits, 10)
    if !parsed {
        return {}, false
    }

    if len(id) != size_of(wire.Session_Id) {
        return {}, false
    }

    session: [size_of(wire.Session_Id)]u8
    copy(session[:], id)

    // A cursor id is compared against stored ids as an opaque blob, so a token outside the
    // id grammar could only ever match nothing. Rejecting it names the fault instead.
    if wire.enforce_id(session) != .None {
        return {}, false
    }

    return {updated_at_ms = updated_at_ms, id = wire.Session_Id(session)}, true
}
