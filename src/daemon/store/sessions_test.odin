package store

import "core:mem"
import "core:testing"

import "libs:testsupport"
import "src:wire"

// Every filter these tests use, spelled once. `all`/`all` is the widest view and the
// baseline the narrower ones are compared against.
@(private = "file")
FILTER_EVERY :: Session_Filter {
    scope      = wire.Session_Scope_All{},
    population = wire.Session_Population_All{},
}

@(private = "file")
FILTER_TOP_LEVEL :: Session_Filter {
    scope      = wire.Session_Scope_All{},
    population = wire.Session_Population_Top_Level{},
}

// A registry row with the fields the page orders and filters on set explicitly; every
// other field follows `test_session_summary`.
@(private = "file")
page_session :: proc(
    id: wire.Session_Id,
    updated_at_ms: u64,
    workspace: Maybe(wire.Workspace_Id) = nil,
    origin: wire.Session_Origin = wire.Session_Origin_Root{},
) -> wire.Session {
    session := test_session_summary(id)
    session.updated_at_ms = updated_at_ms
    session.origin = origin

    if id, named := workspace.?; named do session.workspace_id = id

    // A creator is carried by exactly the user-created arms; a daemon-created child or cron
    // session must not have one, and the store refuses a row that does.
    #partial switch _ in origin {
    case wire.Session_Origin_Child, wire.Session_Origin_Cron:
        session.created_by = nil
    }

    return session
}

@(private = "file")
page_store :: proc(t: ^testing.T, name: string, sessions: ..wire.Session) -> (^Store, string) {
    path := testsupport.sqlite_db_path(t, name)

    s, err := open(path)
    testing.expect_value(t, err, nil)

    for session in sessions {
        _, create_err := session_create(s, test_workspace(session.workspace_id), session, nil)
        testing.expect_value(t, create_err, nil)
    }

    return s, path
}

// The whole point of the index: newest first, and `id DESC` breaking a shared timestamp
// so two sessions updated in the same millisecond still have one total order.
@(test)
test_session_page_orders_by_recency_then_id :: proc(t: ^testing.T) {
    arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena, context.allocator, context.allocator)
    defer mem.dynamic_arena_destroy(&arena)

    older := test_session(0x01)
    tied_low := test_session(0x02)
    tied_high := test_session(0x03)

    s, path := page_store(
        t,
        "page_order",
        page_session(older, 10),
        page_session(tied_low, 20),
        page_session(tied_high, 20),
    )
    defer testsupport.sqlite_db_remove(path)
    defer close(s)

    page, err := session_page(s, FILTER_EVERY, nil, 10, mem.dynamic_arena_allocator(&arena))
    testing.expect_value(t, err, nil)
    testing.expect_value(t, len(page), 3)

    testing.expect_value(t, page[0].id, tied_high)
    testing.expect_value(t, page[1].id, tied_low)
    testing.expect_value(t, page[2].id, older)
}

// A cursor resumes strictly below the row it names, so walking page by page visits every
// session exactly once — including across a tie, which is what the id half is for.
@(test)
test_session_page_cursor_walks_every_row_once :: proc(t: ^testing.T) {
    arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena, context.allocator, context.allocator)
    defer mem.dynamic_arena_destroy(&arena)

    allocator := mem.dynamic_arena_allocator(&arena)

    ids := [4]wire.Session_Id{test_session(0x01), test_session(0x02), test_session(0x03), test_session(0x04)}

    // Two pairs sharing a timestamp, so both pages straddle a tie.
    s, path := page_store(
        t,
        "page_cursor",
        page_session(ids[0], 10),
        page_session(ids[1], 10),
        page_session(ids[2], 20),
        page_session(ids[3], 20),
    )
    defer testsupport.sqlite_db_remove(path)
    defer close(s)

    seen: [dynamic]wire.Session_Id
    defer delete(seen)

    cursor: Maybe(Session_Cursor)
    for {
        page, err := session_page(s, FILTER_EVERY, cursor, 2, allocator)
        testing.expect_value(t, err, nil)

        if len(page) == 0 do break

        for session in page {
            append(&seen, session.id)
        }

        last := page[len(page) - 1]
        cursor = Session_Cursor {
            updated_at_ms = last.updated_at_ms,
            id            = last.id,
        }
    }

    testing.expect_value(t, len(seen), 4)
    testing.expect_value(t, seen[0], ids[3])
    testing.expect_value(t, seen[1], ids[2])
    testing.expect_value(t, seen[2], ids[1])
    testing.expect_value(t, seen[3], ids[0])
}

// `top_level` is the only population that reads the discriminator, and it admits exactly
// root and fork.
@(test)
test_session_page_top_level_admits_root_and_fork :: proc(t: ^testing.T) {
    arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena, context.allocator, context.allocator)
    defer mem.dynamic_arena_destroy(&arena)

    root := test_session(0x01)
    fork := test_session(0x02)
    child := test_session(0x03)
    cron := test_session(0x04)

    s, path := page_store(
        t,
        "page_top_level",
        page_session(root, 40),
        page_session(fork, 30, origin = wire.Session_Origin_Fork{source_id = root}),
        page_session(
            child,
            20,
            origin = wire.Session_Origin_Child{parent_id = root, parent_message_id = 1, parent_part_id = 0},
        ),
        page_session(cron, 10, origin = wire.Session_Origin_Cron{job_id = wire.Job_Id(test_session(0x09))}),
    )
    defer testsupport.sqlite_db_remove(path)
    defer close(s)

    page, err := session_page(s, FILTER_TOP_LEVEL, nil, 10, mem.dynamic_arena_allocator(&arena))
    testing.expect_value(t, err, nil)
    testing.expect_value(t, len(page), 2)
    testing.expect_value(t, page[0].id, root)
    testing.expect_value(t, page[1].id, fork)

    total, count_err := session_count(s, FILTER_TOP_LEVEL)
    testing.expect_value(t, count_err, nil)
    testing.expect_value(t, total, u64(2))
}

// Scope and population are independent predicates: narrowing one must not widen the other.
@(test)
test_session_page_scope_and_population_compose :: proc(t: ^testing.T) {
    arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena, context.allocator, context.allocator)
    defer mem.dynamic_arena_destroy(&arena)

    here := wire.Workspace_Id(test_session(0xaa))
    elsewhere := wire.Workspace_Id(test_session(0xbb))

    parent := test_session(0x01)
    mine := test_session(0x02)
    theirs := test_session(0x03)

    child :: proc(parent: wire.Session_Id) -> wire.Session_Origin {
        return wire.Session_Origin_Child{parent_id = parent, parent_message_id = 1, parent_part_id = 0}
    }

    s, path := page_store(
        t,
        "page_compose",
        page_session(parent, 40, workspace = here),
        page_session(mine, 30, workspace = here, origin = child(parent)),
        page_session(theirs, 20, workspace = elsewhere, origin = child(parent)),
    )
    defer testsupport.sqlite_db_remove(path)
    defer close(s)

    filter := Session_Filter {
        scope = wire.Session_Scope_Workspace{workspace_id = here},
        population = wire.Session_Population_Children{parent_id = parent},
    }

    page, err := session_page(s, filter, nil, 10, mem.dynamic_arena_allocator(&arena))
    testing.expect_value(t, err, nil)
    testing.expect_value(t, len(page), 1)
    testing.expect_value(t, page[0].id, mine)

    // The same population without the workspace restriction reaches both children.
    wider := filter
    wider.scope = wire.Session_Scope_All{}

    total, count_err := session_count(s, wider)
    testing.expect_value(t, count_err, nil)
    testing.expect_value(t, total, u64(2))
}

// `total` describes the selected view, not the page handed back, so a client can size a
// scrollbar from the first page.
@(test)
test_session_count_ignores_the_page_bound :: proc(t: ^testing.T) {
    arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena, context.allocator, context.allocator)
    defer mem.dynamic_arena_destroy(&arena)

    s, path := page_store(
        t,
        "page_total",
        page_session(test_session(0x01), 10),
        page_session(test_session(0x02), 20),
        page_session(test_session(0x03), 30),
    )
    defer testsupport.sqlite_db_remove(path)
    defer close(s)

    page, err := session_page(s, FILTER_EVERY, nil, 1, mem.dynamic_arena_allocator(&arena))
    testing.expect_value(t, err, nil)
    testing.expect_value(t, len(page), 1)

    total, count_err := session_count(s, FILTER_EVERY)
    testing.expect_value(t, count_err, nil)
    testing.expect_value(t, total, u64(3))
}

// An empty database pages and counts rather than failing, and a filter that matches
// nothing behaves the same as an empty table.
@(test)
test_session_page_empty_selection_is_not_an_error :: proc(t: ^testing.T) {
    arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena, context.allocator, context.allocator)
    defer mem.dynamic_arena_destroy(&arena)

    s, path := page_store(t, "page_empty", page_session(test_session(0x01), 10))
    defer testsupport.sqlite_db_remove(path)
    defer close(s)

    filter := Session_Filter {
        scope = wire.Session_Scope_Workspace{workspace_id = wire.Workspace_Id(test_session(0xcc))},
        population = wire.Session_Population_All{},
    }

    page, err := session_page(s, filter, nil, 10, mem.dynamic_arena_allocator(&arena))
    testing.expect_value(t, err, nil)
    testing.expect_value(t, len(page), 0)

    total, count_err := session_count(s, filter)
    testing.expect_value(t, count_err, nil)
    testing.expect_value(t, total, u64(0))
}

// The write and read shapes are inverses: whatever `session_create` flattened, the page
// rebuilds field for field, catching any discriminator or arm-id drift between the two.
@(test)
test_session_page_round_trips_every_origin :: proc(t: ^testing.T) {
    arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena, context.allocator, context.allocator)
    defer mem.dynamic_arena_destroy(&arena)

    root := page_session(test_session(0x01), 40, workspace = wire.Workspace_Id(test_session(0xaa)))

    fork := page_session(test_session(0x02), 30, origin = wire.Session_Origin_Fork{source_id = root.id})

    child := page_session(
        test_session(0x03),
        20,
        origin = wire.Session_Origin_Child{parent_id = root.id, parent_message_id = 7, parent_part_id = 3},
    )

    cron := page_session(
        test_session(0x04),
        10,
        origin = wire.Session_Origin_Cron{job_id = wire.Job_Id(test_session(0x0c))},
    )

    // The nullable columns that are not part of an origin arm, exercised on one row so a
    // set and an unset arm are both covered.
    root.max_rounds = 12
    root.agent = "architect"
    cron.max_rounds = nil
    cron.agent = nil
    cron.created_by = nil

    s, path := page_store(t, "page_round_trip", root, fork, child, cron)
    defer testsupport.sqlite_db_remove(path)
    defer close(s)

    page, err := session_page(s, FILTER_EVERY, nil, 10, mem.dynamic_arena_allocator(&arena))
    testing.expect_value(t, err, nil)
    testing.expect_value(t, len(page), 4)

    for want, i in ([]wire.Session{root, fork, child, cron}) {
        testing.expect_value(t, page[i], want)
    }
}
