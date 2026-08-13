-- name: Insert_Workspace :exec
-- `id` and `title` are both derived from `root`, so a repeat insert carries the same
-- values and has nothing to update. The caller reads `changes` to learn whether the
-- workspace was new, which is what decides the `workspace.created` broadcast. The
-- conflict target is named: a second id claiming a registered root is not a
-- re-registration and must fail `UNIQUE (root)` rather than be absorbed here.
-- id: wire.Workspace_Id!
-- root: string!
-- title: string!
INSERT INTO workspaces(id, root, title) VALUES (:id, :root, :title)
    ON CONFLICT(id) DO NOTHING;

-- name: Workspace_Page :many
-- The whole registry, bounded by the caller's limit. Ordered by root so the snapshot a
-- client receives is stable across restarts rather than hash order.
-- limit: int!
-- id: wire.Workspace_Id!
-- root: string!
-- title: string!
SELECT id, root, title FROM workspaces ORDER BY root LIMIT :limit;
