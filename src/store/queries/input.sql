-- name: InsertPendingInput :exec
-- session_id: [16]u8!
-- input_id: u64!
-- seq: u64!
-- source: ?[]const u8!
INSERT INTO pending_inputs(session_id, input_id, seq, source)
    VALUES (:session_id, :input_id, :seq, :source);

-- name: PendingInputById :optional
-- The input.queued event holds the content; the name checks the source kind.
-- session_id: [16]u8!
-- input_id: u64!
-- row_input_id: u64!
-- seq: u64!
-- payload: []const u8!
-- event_name: []const u8!
SELECT p.input_id AS row_input_id,
       p.seq,
       e.payload,
       e.name AS event_name
FROM pending_inputs p
JOIN events e ON e.session_id = p.session_id AND e.seq = p.seq
WHERE p.session_id = :session_id AND p.input_id = :input_id;

-- name: PendingInputs :many
-- row-from: PendingInputById
-- Return pending inputs in event order.
-- session_id: [16]u8!
SELECT p.input_id AS row_input_id,
       p.seq,
       e.payload,
       e.name AS event_name
FROM pending_inputs p
JOIN events e ON e.session_id = p.session_id AND e.seq = p.seq
WHERE p.session_id = :session_id
ORDER BY p.seq ASC;

-- name: PendingInputCount :one
-- Return the queue depth without a read of the queued payload.
-- session_id: [16]u8!
-- depth: i64!
SELECT count(*) AS depth
FROM pending_inputs
WHERE session_id = :session_id;

-- name: DeletePendingInput :one
-- Delete one exact projection row. An absent row returns NoRow.
-- session_id: [16]u8!
-- input_id: u64!
-- deleted: i64!
DELETE FROM pending_inputs
WHERE session_id = :session_id AND input_id = :input_id
RETURNING 1 AS deleted;

-- name: ChildReportCredits :one
-- A reservation follows each descendant input or turn up to the root report.
-- parent_id: [16]u8!
-- used: i64!
WITH RECURSIVE tree(id) AS (
    SELECT id FROM sessions WHERE parent_id = :parent_id
    UNION
    SELECT s.id FROM sessions s JOIN tree t ON s.parent_id = t.id
)
SELECT
    (SELECT count(*) FROM pending_inputs p JOIN tree t ON t.id = p.session_id) +
    (SELECT count(*) FROM sessions s JOIN tree t ON t.id = s.id WHERE s.open_run_kind = 'turn') +
    (SELECT count(*) FROM pending_inputs WHERE session_id = :parent_id AND source IN ('child_report', 'child_input_canceled')) AS used;

-- name: ProtectedInputCount :one
-- A protected entry is an engine report or notice, never a work request.
-- session_id: [16]u8!
-- depth: i64!
SELECT count(*) AS depth FROM pending_inputs
WHERE session_id = :session_id AND source <> 'parent_instruction';
