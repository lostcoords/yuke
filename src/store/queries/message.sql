-- name: InsertMessage :exec
-- Store one metadata row for each committed message; keep the full body in events.payload and join it by session_id and seq.
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
-- tokens_estimate: u64!
-- reasoning_estimate: u64!
INSERT INTO messages(
    session_id, message_id, seq, role, run_id, config_rev, model, protocol, finish,
    tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, cost, created_at_ms, tokens_estimate, reasoning_estimate
) VALUES (
    :session_id, :message_id, :seq, :role, :run_id, :config_rev, :model, :protocol, :finish,
    :tokens_input, :tokens_output, :tokens_reasoning, :tokens_cache_read, :tokens_cache_write, :cost, :created_at_ms, :tokens_estimate, :reasoning_estimate
);

-- name: AdvanceMessage :one
-- Raise the session summary when a message commits: count, token totals, the id mark, and projection seq; RETURNING yields no row for an absent session, so the caller sees NoRow.
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

-- name: MessagePage :many
-- Return one backward page of committed messages, newest first; the caller reverses it to oldest-first, and the body comes from events.payload joined by (session_id, seq) with cursor_message_id exclusive.
-- session_id: [16]u8!
-- cursor_message_id: u64!
-- limit: i64!
-- message_id: u64!
-- payload: []const u8!
SELECT m.message_id AS message_id, e.payload AS payload
FROM messages m JOIN events e ON e.session_id = m.session_id AND e.seq = m.seq
WHERE m.session_id = :session_id AND m.message_id < :cursor_message_id
ORDER BY m.message_id DESC
LIMIT :limit;

-- name: MessageTail :many
-- row-from: MessagePage
-- Return the newest `limit` committed messages oldest-first, so a load appends them in order.
-- session_id: [16]u8!
-- limit: i64!
SELECT t.message_id AS message_id, e.payload AS payload
FROM (
    SELECT session_id, message_id, seq FROM messages
    WHERE session_id = :session_id
    ORDER BY message_id DESC
    LIMIT :limit
) t JOIN events e ON e.session_id = t.session_id AND e.seq = t.seq
ORDER BY t.message_id ASC;

-- name: LastAssistantUsage :optional
-- Return the newest committed assistant usage for the live context gauge, or no row; the session_context view serves the same value for a page.
-- session_id: [16]u8!
-- tokens_input: ?u64!
-- tokens_output: ?u64!
-- tokens_reasoning: ?u64!
-- tokens_cache_read: ?u64!
-- tokens_cache_write: ?u64!
SELECT tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write
FROM messages
WHERE session_id = :session_id AND role = 'assistant' AND tokens_input IS NOT NULL
ORDER BY message_id DESC
LIMIT 1;

-- name: RunReportMessages :many
-- Read only this run's committed assistant output, newest first.
-- session_id: [16]u8!
-- run_id: u64!
-- payload: []const u8!
SELECT e.payload FROM messages m JOIN events e ON e.session_id = m.session_id AND e.seq = m.seq
WHERE m.session_id = :session_id AND m.run_id = :run_id AND m.role = 'assistant'
ORDER BY m.message_id DESC;

-- name: ContextSizes :many
-- Read the token estimate of each committed message, newest first, before any body enters the request arena. Another model drops the reasoning share.
-- session_id: [16]u8!
-- model: []const u8!
-- first_message_id: u64!
-- message_id: u64!
-- role: []const u8!
-- tokens: u64!
SELECT message_id, role, tokens_estimate - CASE WHEN model IS :model THEN 0 ELSE reasoning_estimate END AS tokens
FROM messages
WHERE session_id = :session_id AND message_id >= :first_message_id AND role <> 'compaction'
ORDER BY message_id DESC;

-- name: ContextCount :one
-- Read the parts of the next request count. The anchor is the newest nonzero provider input after the checkpoint, when the session model gave it.
-- A provider that omits usage records zero, so zero anchors nothing. The sum starts at the anchor, or at the first kept message with no anchor.
-- session_id: [16]u8!
-- model: []const u8!
-- checkpoint_id: u64!
-- first_message_id: u64!
-- anchor_input: ?u64!
-- tokens: u64!
WITH newest AS (
    SELECT message_id, tokens_input, model IS :model AS own
    FROM messages
    WHERE session_id = :session_id AND role = 'assistant' AND tokens_input > 0 AND message_id > :checkpoint_id
    ORDER BY message_id DESC
    LIMIT 1
), anchor AS (SELECT message_id, tokens_input FROM newest WHERE own)
SELECT (SELECT tokens_input FROM anchor) AS anchor_input,
    COALESCE(SUM(tokens_estimate - CASE WHEN model IS :model THEN 0 ELSE reasoning_estimate END), 0) AS tokens
FROM messages
WHERE session_id = :session_id AND role <> 'compaction'
    AND message_id >= COALESCE((SELECT message_id FROM anchor), :first_message_id);

-- name: ContextMessages :many
-- row-from: MessagePage
-- Read the selected committed range in transcript order.
-- session_id: [16]u8!
-- first_message_id: u64!
-- stop_message_id: u64
SELECT m.message_id, e.payload
FROM messages m JOIN events e ON e.session_id = m.session_id AND e.seq = m.seq
WHERE m.session_id = :session_id AND m.message_id >= :first_message_id
AND m.message_id < COALESCE(:stop_message_id, 9223372036854775807)
ORDER BY m.message_id ASC;

-- name: NewestCompaction :optional
-- Read the newest compaction row, which stands for every message it covers.
-- session_id: [16]u8!
-- message_id: u64!
-- payload: []const u8!
SELECT m.message_id, e.payload
FROM messages m JOIN events e ON e.session_id = m.session_id AND e.seq = m.seq
WHERE m.session_id = :session_id AND m.role = 'compaction'
ORDER BY m.message_id DESC
LIMIT 1;
