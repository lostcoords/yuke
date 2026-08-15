package daemon

import "core:log"
import "core:mem"
import "core:slice"
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
// SQLite, at the daemon's current index revision. Each row's activity comes from the
// engine, so a listed session and a resync of that session report the same state.
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

    // `active` selects what the engine tracks, which lives in memory rather than the
    // registry. `active_recent` still orders like `recent`.
    if params.view == .Active {
        session_list_active(conn, req, filter, sa)
        return
    }

    cursor, limit, window_ok := session_list_window(conn, req, filter, sa)
    if !window_ok {
        return
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
            session  = session,
            activity = session_activity(d, session.id),
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

// The page both views open on: the resume position a cursor names and the page size. Both
// grammars are identical, so a client pages the SQL view and the engine view the same way.
// Answers `Bad_Request` itself; `false` means the request is already answered.
@(private = "file")
session_list_window :: proc(
    conn: ^Conn,
    req: wire.Request,
    filter: store.Session_Filter,
    sa: mem.Allocator,
) -> (
    cursor: Maybe(store.Session_Cursor),
    limit: int,
    ok: bool,
) {
    params := req.params.(wire.Session_List_Params)

    if token, paging := params.cursor.?; paging {
        position, valid := session_cursor_decode(token, filter)

        if !valid {
            send_error(conn, req.id, .Bad_Request, "malformed session.list cursor", sa)

            return nil, 0, false
        }

        cursor = position
    }

    // Already validated to be within bounds; default when omitted.
    limit = wire.LIMITS.default_session_list_page_size
    if requested, requested_ok := params.limit.?; requested_ok {
        limit = int(requested)
    }

    assert(limit > 0, "a validated page size is positive")

    return cursor, limit, true
}

// `session.list` at `view = active`: paged over the engine's map instead of SQL, on the
// same keyset and cursor grammar, so a client pages both views identically.
@(private = "file")
session_list_active :: proc(conn: ^Conn, req: wire.Request, filter: store.Session_Filter, sa: mem.Allocator) {
    d := conn.daemon

    resume, limit, window_ok := session_list_window(conn, req, filter, sa)
    if !window_ok {
        return
    }

    items, items_err := make([dynamic]wire.Session_List_Item, 0, len(d.sessions), sa)
    if items_err != nil {
        send_error(conn, req.id, .Internal, "session index unavailable", sa)

        return
    }

    for id in d.sessions {
        snapshot, found, serr := store.session_snapshot(d.store, id, sa)

        if serr != nil {
            log.errorf("daemon: session.list could not read active session %v: %v", id, serr)
            send_error(conn, req.id, .Internal, "session index unavailable", sa)

            return
        }

        // A tracked id with no row lost a race with `session.removed`, not an invariant.
        if !found || !session_filter_matches(filter, snapshot.session) {
            continue
        }

        if _, err := append(
            &items,
            wire.Session_List_Item{session = snapshot.session, activity = session_activity(d, id)},
        ); err != nil {
            send_error(conn, req.id, .Internal, "session index unavailable", sa)

            return
        }
    }

    // Map iteration is unordered, so this is what makes the answer reproducible at all.
    slice.sort_by(items[:], proc(a, b: wire.Session_List_Item) -> bool {
        if a.session.updated_at_ms != b.session.updated_at_ms {
            return a.session.updated_at_ms > b.session.updated_at_ms
        }

        return session_id_greater(a.session.id, b.session.id)
    })

    // `total` describes the whole selection on every page, as it does for the registry.
    page := items[:]
    total := u64(len(page))

    // Resume strictly below the cursor. The position is exclusive on both terms, so no row
    // repeats across pages and none between them is skipped.
    if position, paging := resume.?; paging {
        for item, index in page {
            below :=
                item.session.updated_at_ms < position.updated_at_ms ||
                (item.session.updated_at_ms == position.updated_at_ms &&
                        session_id_greater(position.id, item.session.id))

            if below {
                page = page[index:]
                break
            }

            if index == len(page) - 1 {
                page = nil
            }
        }
    }

    result := wire.Session_List_Result {
        revision = d.session_revision,
        items    = page,
        total    = total,
    }

    // Minted only when a row remains, so a null continuation really does end the view.
    if len(page) > limit {
        result.items = page[:limit]
        last := result.items[limit - 1].session
        result.next_cursor = session_cursor_encode(filter, {updated_at_ms = last.updated_at_ms, id = last.id}, sa)
    }

    send_result(conn, req.id, result, sa)
}

// Whether a session belongs to the selection a filter names. `Session_Page` applies this
// same predicate in SQL; this is its in-memory twin, and the two must agree.
@(private = "file")
session_filter_matches :: proc(filter: store.Session_Filter, session: wire.Session) -> bool {
    assert(filter.scope != nil, "a session filter carries its scope")
    assert(filter.population != nil, "a session filter carries its population")

    switch scope in filter.scope {
    case wire.Session_Scope_All:

    case wire.Session_Scope_Workspace:
        if session.workspace_id != scope.workspace_id {
            return false
        }
    }

    switch population in filter.population {
    case wire.Session_Population_All:

    case wire.Session_Population_Top_Level:
        // `origin IN ('root', 'fork')`, the same pair the statement admits.
        switch _ in session.origin {
        case wire.Session_Origin_Root, wire.Session_Origin_Fork:

        case wire.Session_Origin_Child, wire.Session_Origin_Cron:
            return false
        }

    case wire.Session_Population_Children:
        child, is_child := session.origin.(wire.Session_Origin_Child)

        if !is_child || child.parent_id != population.parent_id {
            return false
        }

    case wire.Session_Population_Job_Runs:
        cron, is_cron := session.origin.(wire.Session_Origin_Cron)

        if !is_cron || cron.job_id != population.job_id {
            return false
        }
    }

    return true
}

// The registry's `id DESC` tiebreak. Ids are opaque blobs, so the compare is bytewise.
@(private = "file")
session_id_greater :: proc(a, b: wire.Session_Id) -> bool {
    left := ([16]u8)(a)
    right := ([16]u8)(b)

    for byte, index in left {
        if byte != right[index] {
            return byte > right[index]
        }
    }

    return false
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
