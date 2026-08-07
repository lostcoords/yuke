-- name: Truncate_Messages :exec
-- Truncation is an appended marker that removes *earlier* messages, so the
-- projection folds it rather than mirroring the log row for row.
-- session_id: wire.Session_Id!
-- first_removed_id: wire.Message_Id!
DELETE FROM messages
    WHERE session_id = :session_id AND message_id >= :first_removed_id;

-- name: Count_Messages :exec
-- `delta` is negative on a truncation. A null `updated_at_ms` is an event with
-- no timestamp of its own, which leaves the mark where it is.
-- session_id: wire.Session_Id!
-- delta: i64!
-- updated_at_ms: u64
UPDATE sessions SET
    message_count = message_count + :delta,
    updated_at_ms = MAX(updated_at_ms, COALESCE(:updated_at_ms, 0))
    WHERE id = :session_id;

-- name: Session_History_Page :many
-- The transcript tail as `session.history` pages it: newest message first, each row
-- joined to its body in `events` by (session_id, seq). A null cursor starts at the
-- newest; older pages seek by message id descending. The caller reverses a tail page
-- back to ascending before it ships.
-- session_id: wire.Session_Id!
-- cursor_message_id: wire.Message_Id
-- limit: int!
-- message_id: wire.Message_Id!
-- seq: wire.Seq!
-- payload: string!
SELECT m.message_id, m.seq, e.payload
    FROM messages m
    JOIN events e ON e.session_id = m.session_id AND e.seq = m.seq
    WHERE m.session_id = :session_id
      AND (:cursor_message_id IS NULL OR m.message_id < :cursor_message_id)
    ORDER BY m.message_id DESC
    LIMIT :limit;
