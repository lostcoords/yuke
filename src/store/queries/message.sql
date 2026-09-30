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
-- first_kept_id: ?u64!
INSERT INTO messages(
    session_id, message_id, seq, role, run_id, config_rev, model, protocol, finish,
    tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, cost, created_at_ms, tokens_estimate, reasoning_estimate, first_kept_id
) VALUES (
    :session_id, :message_id, :seq, :role, :run_id, :config_rev, :model, :protocol, :finish,
    :tokens_input, :tokens_output, :tokens_reasoning, :tokens_cache_read, :tokens_cache_write, :cost, :created_at_ms, :tokens_estimate, :reasoning_estimate, :first_kept_id
);

-- name: AdvanceMessage :one
-- Raise the session summary when a message commits: count, token totals, the last usage, the id mark, and projection seq. Null tokens mean that the message reports no usage.
-- RETURNING yields no row for an absent session, so the caller sees NoRow.
-- id: [16]u8!
-- message_id: u64!
-- seq: u64!
-- tokens_input: ?u64!
-- tokens_output: ?u64!
-- tokens_reasoning: ?u64!
-- tokens_cache_read: ?u64!
-- tokens_cache_write: ?u64!
-- cost: ?f64!
-- cost_without_cache: ?f64!
-- updated_at_ms: u64!
-- advanced: i64!
UPDATE sessions SET
    message_count           = message_count + 1,
    message_id_high         = MAX(message_id_high, :message_id),
    usage_input_total       = usage_input_total       + COALESCE(:tokens_input, 0),
    usage_output_total      = usage_output_total      + COALESCE(:tokens_output, 0),
    usage_reasoning_total   = usage_reasoning_total    + COALESCE(:tokens_reasoning, 0),
    usage_cache_read_total  = usage_cache_read_total   + COALESCE(:tokens_cache_read, 0),
    usage_cache_write_total = usage_cache_write_total  + COALESCE(:tokens_cache_write, 0),
    usage_last_input        = COALESCE(:tokens_input, usage_last_input),
    usage_last_output       = COALESCE(:tokens_output, usage_last_output),
    usage_last_reasoning    = COALESCE(:tokens_reasoning, usage_last_reasoning),
    usage_last_cache_read   = COALESCE(:tokens_cache_read, usage_last_cache_read),
    usage_last_cache_write  = COALESCE(:tokens_cache_write, usage_last_cache_write),
    cost_total               = cost_total               + COALESCE(:cost, 0),
    cost_without_cache_total = cost_without_cache_total + COALESCE(:cost_without_cache, 0),
    -- A message with tokens and no known cost is unpriced. A message without tokens is not unpriced.
    unpriced_count           = unpriced_count           + (:tokens_input IS NOT NULL AND :cost IS NULL),
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
-- Count the next request from stored rows. The anchor is the newest nonzero provider input after the newest checkpoint, when `model` gave it.
-- With an anchor, the count is its input plus the estimate from the anchor message on. With none, it is the prompt estimate plus the checkpoint and the kept messages.
-- Another model drops the reasoning share. A provider that omits usage records zero, so zero anchors nothing.
-- A null model or prompt estimate takes the value that the session row stores.
-- session_id: [16]u8!
-- model: ?[]const u8
-- prompt_tokens: ?u64
-- tokens: u64!
WITH inputs AS NOT MATERIALIZED (
    SELECT COALESCE(:model, model) AS model, COALESCE(:prompt_tokens, prompt_tokens) AS prompt_tokens
    FROM sessions
    WHERE id = :session_id
), head AS NOT MATERIALIZED (
    SELECT message_id, first_kept_id AS kept
    FROM messages
    WHERE session_id = :session_id AND role = 'compaction'
    ORDER BY message_id DESC
    LIMIT 1
), newest AS NOT MATERIALIZED (
    SELECT message_id, tokens_input, model IS (SELECT model FROM inputs) AS own
    FROM messages
    WHERE session_id = :session_id AND role = 'assistant' AND tokens_input > 0
        AND message_id > COALESCE((SELECT message_id FROM head), 0)
    ORDER BY message_id DESC
    LIMIT 1
), anchor AS NOT MATERIALIZED (SELECT message_id, tokens_input FROM newest WHERE own)
SELECT COALESCE((SELECT tokens_input FROM anchor), (SELECT prompt_tokens FROM inputs))
    + COALESCE(SUM(tokens_estimate - CASE WHEN model IS (SELECT model FROM inputs) THEN 0 ELSE reasoning_estimate END), 0) AS tokens
FROM messages
WHERE session_id = :session_id
    AND (role <> 'compaction' OR message_id = (SELECT message_id FROM head))
    AND message_id >= COALESCE((SELECT message_id FROM anchor), (SELECT kept FROM head), 0);

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
