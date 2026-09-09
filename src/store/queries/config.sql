-- name: InsertConfig :exec
-- Store one config revision. session.config reads it directly without a log fold.
-- session_id: [16]u8!
-- config_rev: u64!
-- model: []const u8!
-- reasoning: []const u8!
-- max_rounds: ?u64!
INSERT INTO session_configs(session_id, config_rev, model, reasoning, max_rounds)
    VALUES (:session_id, :config_rev, :model, :reasoning, :max_rounds);

-- name: AdvanceConfig :one
-- Set the current config and raise the config mark and projection seq.
-- The guard keeps the mark monotonic. A stale revision yields no row, so the caller sees NoRow.
-- id: [16]u8!
-- config_rev: u64!
-- model: []const u8!
-- reasoning: []const u8!
-- max_rounds: ?u64!
-- seq: u64!
-- updated_at_ms: u64!
-- advanced: i64!
UPDATE sessions SET
    model           = :model,
    reasoning       = :reasoning,
    max_rounds      = :max_rounds,
    config_rev      = :config_rev,
    config_rev_high = MAX(config_rev_high, :config_rev),
    projection_seq  = :seq,
    updated_at_ms   = MAX(updated_at_ms, :updated_at_ms)
WHERE id = :id AND :config_rev >= config_rev_high RETURNING 1 AS advanced;

-- name: ConfigByRevision :optional
-- Read one historical config revision. Keep a superseded revision readable.
-- session_id: [16]u8!
-- config_rev: u64!
-- model: []const u8!
-- reasoning: []const u8!
-- max_rounds: ?u64!
SELECT model, reasoning, max_rounds FROM session_configs WHERE session_id = :session_id AND config_rev = :config_rev;
