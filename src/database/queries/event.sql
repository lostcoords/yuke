-- name: AllocSeq :one
-- Allocate the next seq for one session and return it.
-- SQLite applies the increment atomically; RETURNING avoids a separate read.
-- id: [16]u8!
-- seq_high: u64!
UPDATE sessions SET seq_high = seq_high + 1 WHERE id = :id RETURNING seq_high;

-- name: AppendEvent :exec
-- session_id: [16]u8!
-- seq: u64!
-- name: []const u8!
-- payload: []const u8!
INSERT INTO events(session_id, seq, name, payload) VALUES (:session_id, :seq, :name, :payload);

-- name: BumpIds :one
-- Id marks only increase. A stale bump does not rewind a mark.
-- RETURNING yields no row for a missing session, so the caller sees NoRow.
-- id: [16]u8!
-- message_id_high: u64!
-- run_id_high: u64!
-- input_id_high: u64!
-- config_rev_high: u64!
-- bumped: i64!
UPDATE sessions SET
    message_id_high = MAX(message_id_high, :message_id_high),
    run_id_high     = MAX(run_id_high, :run_id_high),
    input_id_high   = MAX(input_id_high, :input_id_high),
    config_rev_high = MAX(config_rev_high, :config_rev_high)
    WHERE id = :id RETURNING 1 AS bumped;

-- name: ReadHigh :optional
-- Read the id marks for recovery. Return no row when the session does not exist.
-- id: [16]u8!
-- seq_high: u64!
-- message_id_high: u64!
-- run_id_high: u64!
-- input_id_high: u64!
-- config_rev_high: u64!
SELECT seq_high, message_id_high, run_id_high, input_id_high, config_rev_high
    FROM sessions WHERE id = :id;
