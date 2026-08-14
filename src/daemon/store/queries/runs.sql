-- name: Set_Open_Run :exec
-- Record that `run.started` owes a terminal. A second open run overwrites; the pump never
-- emits one, and a corrupt log is caught on read, not here.
-- session_id: wire.Session_Id!
-- open_run_id: wire.Run_Id!
-- open_run_kind: string!
-- open_run_started_at_ms: u64!
UPDATE sessions SET
    open_run_id            = :open_run_id,
    open_run_kind          = :open_run_kind,
    open_run_started_at_ms = :open_run_started_at_ms
    WHERE id = :session_id;

-- name: Clear_Open_Run :exec
-- The terminal was written, so nothing is owed. A done for a different or already-closed
-- run matches nothing, so a queued run canceled before it started leaves the row alone.
-- session_id: wire.Session_Id!
-- open_run_id: wire.Run_Id!
UPDATE sessions SET
    open_run_id            = NULL,
    open_run_kind          = NULL,
    open_run_started_at_ms = NULL
    WHERE id = :session_id AND open_run_id = :open_run_id;

-- name: Reset_Open_Run :exec
-- Clear the marker unconditionally, so a rebuild starts from empty and replays the log —
-- the same reset-then-replay the transcript and configs follow.
-- session_id: wire.Session_Id!
UPDATE sessions SET
    open_run_id            = NULL,
    open_run_kind          = NULL,
    open_run_started_at_ms = NULL
    WHERE id = :session_id;

-- name: Open_Runs :many
-- Every run still owing a terminal, oldest first: the whole repair list for a start.
-- session_id: wire.Session_Id!
-- open_run_id: wire.Run_Id!
-- open_run_kind: string!
-- open_run_started_at_ms: u64!
SELECT id AS session_id, open_run_id, open_run_kind, open_run_started_at_ms
FROM sessions
WHERE open_run_id IS NOT NULL
ORDER BY open_run_started_at_ms ASC, id ASC;
