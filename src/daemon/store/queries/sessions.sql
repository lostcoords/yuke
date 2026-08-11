-- name: Session_Exists :manual
-- Struct-only: no result column worth a name (a bare `1`) — the caller checks
-- `step` returning `.Row` directly, no scan.
-- session_id: wire.Session_Id!
SELECT 1 FROM sessions WHERE id = :session_id;

-- name: Session_Snapshot :one
-- The client-facing summary and open-run projection for one id. Kept separate
-- from `Session_Page` because lookup has no filter, cursor, ordering, or limit.
-- session_id: wire.Session_Id!
-- id: wire.Session_Id!
-- workspace_id: wire.Workspace_Id!
-- origin: string!
-- parent_id: wire.Session_Id
-- parent_message_id: wire.Message_Id
-- parent_part_id: wire.Part_Id
-- source_id: wire.Session_Id
-- job_id: wire.Job_Id
-- profile: string!
-- model: string!
-- reasoning: string!
-- config_rev: wire.Config_Rev!
-- permission: string!
-- max_rounds: u64
-- title: string!
-- agent: string
-- created_by_name: string
-- created_by_version: string
-- message_count: u64!
-- created_at_ms: u64!
-- updated_at_ms: u64!
-- open_run_id: wire.Run_Id
-- open_run_kind: string
-- open_run_reason: string
-- open_run_config_rev: wire.Config_Rev
-- open_run_started_at_ms: u64
SELECT
    id, workspace_id,
    origin, parent_id, parent_message_id, parent_part_id, source_id, job_id,
    profile, model, reasoning, config_rev, permission, max_rounds, title, agent,
    created_by_name, created_by_version,
    message_count, created_at_ms, updated_at_ms,
    open_run_id, open_run_kind, open_run_reason, open_run_config_rev, open_run_started_at_ms
FROM sessions
WHERE id = :session_id;

-- name: Session_Page :many
-- Named rather than `SELECT *`: `sessions` also carries the id-minting marks
-- (`seq_high` and siblings) and the open-run projection, none of which belong in a
-- `session.list` row, so the page selects only the client-facing columns and takes
-- its own `Session_Page_Row` shape.
-- `filter_workspace_id` (not `workspace_id`) avoids colliding with the row's
-- own `workspace_id` column, which is NOT NULL while the filter is optional.
-- filter_workspace_id: wire.Workspace_Id
-- parent_id: wire.Session_Id
-- job_id: wire.Job_Id
-- top_level: bool!
-- cursor_updated_at_ms: u64
-- cursor_id: wire.Session_Id
-- limit: int!
-- id: wire.Session_Id!
-- workspace_id: wire.Workspace_Id!
-- origin: string!
-- parent_message_id: wire.Message_Id
-- parent_part_id: wire.Part_Id
-- source_id: wire.Session_Id
-- profile: string!
-- model: string!
-- reasoning: string!
-- config_rev: wire.Config_Rev!
-- permission: string!
-- max_rounds: u64
-- title: string!
-- agent: string
-- created_by_name: string
-- created_by_version: string
-- message_count: u64!
-- created_at_ms: u64!
-- updated_at_ms: u64!
SELECT
    id, workspace_id,
    origin, parent_id, parent_message_id, parent_part_id, source_id, job_id,
    profile, model, reasoning, config_rev, permission, max_rounds, title, agent,
    created_by_name, created_by_version,
    message_count, created_at_ms, updated_at_ms
FROM sessions
WHERE (:filter_workspace_id IS NULL OR workspace_id = :filter_workspace_id)
  AND (:parent_id    IS NULL OR parent_id    = :parent_id)
  AND (:job_id       IS NULL OR job_id       = :job_id)
  AND (NOT :top_level OR origin IN ('root', 'fork'))
  AND (:cursor_updated_at_ms IS NULL
       OR updated_at_ms < :cursor_updated_at_ms
       OR (updated_at_ms = :cursor_updated_at_ms AND id < :cursor_id))
ORDER BY updated_at_ms DESC, id DESC
LIMIT :limit;

-- name: Session_Count :one
-- The same selector as `Session_Page`, without the keyset or the page bound:
-- `total` counts the whole view a client is paging through, not the page it
-- just received. The WHERE clause is duplicated from `Session_Page` rather
-- than shared — sqlgen has no notion of a fragment shared between queries, and
-- the two must be kept in sync by hand if a selector ever changes.
-- workspace_id: wire.Workspace_Id
-- parent_id: wire.Session_Id
-- job_id: wire.Job_Id
-- top_level: bool!
-- total: u64!
SELECT count(*) AS total FROM sessions
WHERE (:workspace_id IS NULL OR workspace_id = :workspace_id)
  AND (:parent_id    IS NULL OR parent_id    = :parent_id)
  AND (:job_id       IS NULL OR job_id       = :job_id)
  AND (NOT :top_level OR origin IN ('root', 'fork'));
