package store

import "core:mem"

import "src:daemon/store/queries"
import "src:wire"

import "libs:bindings/sqlite"

// Read the whole registry, bounded by `limit`, ordered by root. Every string clones into
// `allocator` and nothing is freed — built for an arena the owner reclaims in bulk.
workspace_page :: proc(s: ^Store, limit: int, allocator: mem.Allocator) -> (workspaces: []wire.Workspace, err: Error) {
    assert(s != nil, "workspace_page needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(limit > 0, "a workspace page is bounded")
    assert(allocator.procedure != nil, "a workspace page needs an allocator")

    read, sqlite_err := queries.workspace_page(&s.queries, {limit = limit}, allocator, cap_hint = limit)
    if sqlite_err != nil {
        return nil, read_err(sqlite_err)
    }

    page, page_err := make([]wire.Workspace, len(read), allocator)
    if page_err != nil {
        return nil, Store_Error.Alloc_Failed
    }

    for row, i in read {
        page[i] = wire.Workspace {
            id    = row.id,
            root  = row.root,
            title = row.title,
        }
    }

    assert(len(page) <= limit, "a page holds no more rows than the statement's LIMIT")

    return page, nil
}

// Register `workspace` unless its root is already known. Runs inside the caller's
// transaction: a workspace is only ever written as part of creating a session into it, so
// a rolled-back session cannot leave behind a workspace the daemon never announced.
@(private)
workspace_insert :: proc(s: ^Store, workspace: wire.Workspace) -> (created: bool, err: Error) {
    assert(s != nil, "workspace_insert needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(len(workspace.root) > 0, "a workspace carries its canonical root")

    queries.insert_workspace(&s.queries, {id = workspace.id, root = workspace.root, title = workspace.title}) or_return

    changed := sqlite.changes(s.writer)
    assert(changed <= 1, "an id-keyed insert writes at most one row")

    return changed == 1, nil
}
