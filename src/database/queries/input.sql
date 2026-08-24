-- name: InsertPendingInput :exec
-- The projection stores the complete wire.misc.QueuedInput JSON.
-- session_id: [16]u8!
-- input_id: u64!
-- seq: u64!
-- queued_at_ms: u64!
-- payload: []const u8!
INSERT INTO pending_inputs(session_id, input_id, seq, queued_at_ms, payload)
    VALUES (:session_id, :input_id, :seq, :queued_at_ms, :payload);

-- name: PendingInputById :optional
-- Include the event body so the projection identity can be checked against its source.
-- session_id: [16]u8!
-- input_id: u64!
-- row_session_id: [16]u8!
-- row_input_id: u64!
-- seq: u64!
-- queued_at_ms: u64!
-- payload: []const u8!
-- event_name: []const u8!
-- event_payload: []const u8!
SELECT p.session_id AS row_session_id,
       p.input_id AS row_input_id,
       p.seq,
       p.queued_at_ms,
       p.payload,
       e.name AS event_name,
       e.payload AS event_payload
FROM pending_inputs p
JOIN events e ON e.session_id = p.session_id AND e.seq = p.seq
WHERE p.session_id = :session_id AND p.input_id = :input_id;

-- name: PendingInputs :many
-- Return pending inputs in event order.
-- session_id: [16]u8!
-- row_session_id: [16]u8!
-- row_input_id: u64!
-- seq: u64!
-- queued_at_ms: u64!
-- payload: []const u8!
-- event_name: []const u8!
-- event_payload: []const u8!
SELECT p.session_id AS row_session_id,
       p.input_id AS row_input_id,
       p.seq,
       p.queued_at_ms,
       p.payload,
       e.name AS event_name,
       e.payload AS event_payload
FROM pending_inputs p
JOIN events e ON e.session_id = p.session_id AND e.seq = p.seq
WHERE p.session_id = :session_id
ORDER BY p.seq ASC;

-- name: DeletePendingInput :one
-- Delete one exact projection row. A missing row returns NoRow.
-- session_id: [16]u8!
-- input_id: u64!
-- deleted: i64!
DELETE FROM pending_inputs
WHERE session_id = :session_id AND input_id = :input_id
RETURNING 1 AS deleted;

-- name: PendingSessionIds :many
-- Return sessions that have at least one pending input.
-- session_id: [16]u8!
SELECT DISTINCT session_id
FROM pending_inputs
ORDER BY session_id;
