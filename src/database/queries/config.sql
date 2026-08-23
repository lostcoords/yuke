-- name: InsertConfig :exec
-- One config revision. session.config reads it back directly, without folding the log.
-- session_id: [16]u8!
-- config_rev: u64!
-- model: []const u8!
-- reasoning: []const u8!
INSERT INTO session_configs(session_id, config_rev, model, reasoning)
    VALUES (:session_id, :config_rev, :model, :reasoning);

-- name: AdvanceConfig :one
-- Set the session's current config and raise the config mark and the projection seq. RETURNING yields
-- no row for a missing session, so the caller sees NoRow.
-- id: [16]u8!
-- config_rev: u64!
-- model: []const u8!
-- reasoning: []const u8!
-- seq: u64!
-- updated_at_ms: u64!
-- advanced: i64!
UPDATE sessions SET
    model           = :model,
    reasoning       = :reasoning,
    config_rev      = :config_rev,
    config_rev_high = MAX(config_rev_high, :config_rev),
    projection_seq  = :seq,
    updated_at_ms   = MAX(updated_at_ms, :updated_at_ms)
WHERE id = :id RETURNING 1 AS advanced;
