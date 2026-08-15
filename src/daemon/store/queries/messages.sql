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

-- name: Last_Assistant_Usage :one
-- The newest committed assistant turn that reported usage, for the live context gauge.
-- A session with no reported usage yet returns no row.
-- session_id: wire.Session_Id!
-- tokens_input: u64
-- tokens_output: u64
-- tokens_reasoning: u64
-- tokens_cache_read: u64
-- tokens_cache_write: u64
SELECT tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write
    FROM messages
    WHERE session_id = :session_id AND role = 'assistant' AND tokens_input IS NOT NULL
    ORDER BY message_id DESC
    LIMIT 1;

-- name: Add_Session_Usage :exec
-- Fold one assistant turn's usage into the session's lifetime totals, inside the append
-- transaction. Monotonic: only a committed turn calls this, and truncation never subtracts.
-- session_id: wire.Session_Id!
-- input: u64!
-- output: u64!
-- reasoning: u64!
-- cache_read: u64!
-- cache_write: u64!
UPDATE sessions SET
    usage_input_total       = usage_input_total       + :input,
    usage_output_total      = usage_output_total      + :output,
    usage_reasoning_total   = usage_reasoning_total    + :reasoning,
    usage_cache_read_total  = usage_cache_read_total   + :cache_read,
    usage_cache_write_total = usage_cache_write_total  + :cache_write
    WHERE id = :session_id;

-- name: Reset_Session_Usage :exec
-- Zero the lifetime usage totals ahead of a projection rebuild, which then re-accumulates
-- them by replaying every committed turn. Paired with the transcript reset, never called live.
-- session_id: wire.Session_Id!
UPDATE sessions SET
    usage_input_total       = 0,
    usage_output_total      = 0,
    usage_reasoning_total   = 0,
    usage_cache_read_total  = 0,
    usage_cache_write_total = 0
    WHERE id = :session_id;
