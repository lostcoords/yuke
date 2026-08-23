-- name: InsertMessage :exec
-- One committed-message metadata row. The full body stays in events.payload, joined by (session_id, seq).
-- session_id: [16]u8!
-- message_id: u64!
-- seq: u64!
-- role: []const u8!
-- run_id: ?u64!
-- config_rev: ?u64!
-- model: ?[]const u8!
-- protocol: ?[]const u8!
-- finish: ?[]const u8!
-- tokens_input: ?u64!
-- tokens_output: ?u64!
-- tokens_reasoning: ?u64!
-- tokens_cache_read: ?u64!
-- tokens_cache_write: ?u64!
-- cost: ?f64!
-- created_at_ms: u64!
INSERT INTO messages(
    session_id, message_id, seq, role, run_id, config_rev, model, protocol, finish,
    tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, cost, created_at_ms
) VALUES (
    :session_id, :message_id, :seq, :role, :run_id, :config_rev, :model, :protocol, :finish,
    :tokens_input, :tokens_output, :tokens_reasoning, :tokens_cache_read, :tokens_cache_write, :cost, :created_at_ms
);

-- name: AdvanceMessage :one
-- Raise the session summary when a message commits: count, token totals, the id mark, and the
-- projection seq. RETURNING yields no row for a missing session, so the caller sees NoRow.
-- id: [16]u8!
-- message_id: u64!
-- seq: u64!
-- add_input: u64!
-- add_output: u64!
-- add_reasoning: u64!
-- add_cache_read: u64!
-- add_cache_write: u64!
-- updated_at_ms: u64!
-- advanced: i64!
UPDATE sessions SET
    message_count           = message_count + 1,
    message_id_high         = MAX(message_id_high, :message_id),
    usage_input_total       = usage_input_total       + :add_input,
    usage_output_total      = usage_output_total      + :add_output,
    usage_reasoning_total   = usage_reasoning_total    + :add_reasoning,
    usage_cache_read_total  = usage_cache_read_total   + :add_cache_read,
    usage_cache_write_total = usage_cache_write_total  + :add_cache_write,
    projection_seq          = :seq,
    updated_at_ms           = MAX(updated_at_ms, :updated_at_ms)
WHERE id = :id RETURNING 1 AS advanced;
