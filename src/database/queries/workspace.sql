-- name: WorkspaceByStableKey :optional
-- Find a workspace by its deduplication key. An ephemeral workspace has no key and never matches.
-- kind: []const u8!
-- stable_key: []const u8!
-- id: [16]u8!
SELECT id FROM workspaces WHERE kind = :kind AND stable_key = :stable_key;

-- name: InsertWorkspace :exec
-- id: [16]u8!
-- kind: []const u8!
-- root: []const u8!
-- title: []const u8!
-- stable_key: ?[]const u8!
INSERT INTO workspaces(id, kind, root, title, stable_key)
    VALUES (:id, :kind, :root, :title, :stable_key);

-- name: WorkspaceById :optional
-- id: [16]u8!
-- kind: []const u8!
-- root: []const u8!
-- title: []const u8!
SELECT id, kind, root, title FROM workspaces WHERE id = :id;
