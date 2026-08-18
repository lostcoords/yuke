package store

import "core:testing"

import "libs:testsupport"
import "src:wire"

// The first session in a workspace registers it; every later one matches the existing row,
// which is exactly what tells the daemon whether to announce `workspace.created`.
@(test)
test_a_workspace_is_registered_once :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "workspace-register-once")
    defer testsupport.sqlite_db_remove(path)

    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)

    first := test_session_summary(test_session(0x11))
    second := test_session_summary(test_session(0x12))
    workspace := test_workspace(first.workspace_id)

    created, first_err := session_create(s, workspace, first, nil)
    testing.expect_value(t, first_err, nil)
    testing.expect(t, created, "the first session in a workspace registers it")

    again, second_err := session_create(s, workspace, second, nil)
    testing.expect_value(t, second_err, nil)
    testing.expect(t, !again, "a second session finds the workspace already known")

    page, page_err := workspace_page(s, 8, context.temp_allocator)
    testing.expect_value(t, page_err, nil)

    if testing.expect_value(t, len(page), 1) {
        testing.expect_value(t, page[0].id, workspace.id)
        testing.expect_value(t, page[0].root, workspace.root)
        testing.expect_value(t, page[0].title, workspace.title)
    }

    // A third session in its own directory registers a second workspace; the snapshot is
    // ordered by root and honours the caller's bound.
    elsewhere := test_session_summary(test_session(0x13))
    elsewhere.workspace_id = wire.Workspace_Id(test_session(0x13))
    _, elsewhere_err := session_create(s, test_workspace(elsewhere.workspace_id), elsewhere, nil)
    testing.expect_value(t, elsewhere_err, nil)

    both, both_err := workspace_page(s, 8, context.temp_allocator)
    testing.expect_value(t, both_err, nil)

    if testing.expect_value(t, len(both), 2) do testing.expect(t, both[0].root < both[1].root, "the snapshot is ordered by root")

    bounded, bounded_err := workspace_page(s, 1, context.temp_allocator)
    testing.expect_value(t, bounded_err, nil)
    testing.expect_value(t, len(bounded), 1)
}
