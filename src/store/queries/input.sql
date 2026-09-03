-- name: InsertPendingInput :exec
-- The projection stores the complete proto.misc.QueuedInput JSON.
-- session_id: [16]u8!
-- input_id: u64!
-- seq: u64!
-- queued_at_ms: u64!
-- payload: []const u8!
INSERT INTO pending_inputs(session_id, input_id, seq, queued_at_ms, payload)
    VALUES (:session_id, :input_id, :seq, :queued_at_ms, :payload);

-- name: PendingInputById :optional
-- Include the event name to check the projection source kind.
-- session_id: [16]u8!
-- input_id: u64!
-- row_input_id: u64!
-- seq: u64!
-- queued_at_ms: u64!
-- payload: []const u8!
-- event_name: []const u8!
SELECT p.input_id AS row_input_id,
       p.seq,
       p.queued_at_ms,
       p.payload,
       e.name AS event_name
FROM pending_inputs p
JOIN events e ON e.session_id = p.session_id AND e.seq = p.seq
WHERE p.session_id = :session_id AND p.input_id = :input_id;

-- name: PendingInputs :many
-- Return pending inputs in event order.
-- session_id: [16]u8!
-- row_input_id: u64!
-- seq: u64!
-- queued_at_ms: u64!
-- payload: []const u8!
-- event_name: []const u8!
SELECT p.input_id AS row_input_id,
       p.seq,
       p.queued_at_ms,
       p.payload,
       e.name AS event_name
FROM pending_inputs p
JOIN events e ON e.session_id = p.session_id AND e.seq = p.seq
WHERE p.session_id = :session_id
ORDER BY p.seq ASC;

-- name: DeletePendingInput :one
-- Delete one exact projection row. An absent row returns NoRow.
-- session_id: [16]u8!
-- input_id: u64!
-- deleted: i64!
DELETE FROM pending_inputs
WHERE session_id = :session_id AND input_id = :input_id
RETURNING 1 AS deleted;
