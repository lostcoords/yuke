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
