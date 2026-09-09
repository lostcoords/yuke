-- name: InsertSession :exec
-- The insert omits counters, usage totals, high-water marks, and open-run fields.
-- id: [16]u8!
-- root: []const u8!
-- origin: []const u8!
-- parent_id: ?[16]u8!
-- parent_message_id: ?u64!
-- parent_part_id: ?u64!
-- source_id: ?[16]u8!
-- profile: []const u8!
-- model: []const u8!
-- reasoning: []const u8!
-- config_rev: u64!
-- max_rounds: ?u64!
-- title: []const u8!
-- agent: ?[]const u8!
-- name: ?[]const u8!
-- created_by_name: ?[]const u8!
-- created_by_version: ?[]const u8!
-- created_at_ms: u64!
-- updated_at_ms: u64!
INSERT INTO sessions(
    id, root, origin, parent_id, parent_message_id, parent_part_id, source_id,
    profile, model, reasoning, config_rev, max_rounds, title, agent, name,
    created_by_name, created_by_version, created_at_ms, updated_at_ms
) VALUES (
    :id, :root, :origin, :parent_id, :parent_message_id, :parent_part_id, :source_id,
    :profile, :model, :reasoning, :config_rev, :max_rounds, :title, :agent, :name,
    :created_by_name, :created_by_version, :created_at_ms, :updated_at_ms
);

-- name: SessionExists :optional
-- id: [16]u8!
-- present: i64!
SELECT 1 AS present FROM sessions WHERE id = :id;

-- name: SessionSnapshot :optional
-- Return the summary for the client and the open-run terminal marker for one id.
-- Omit the id allocation marks because callers allocate them in write transactions.
-- id: [16]u8!
-- root: []const u8!
-- origin: []const u8!
-- parent_id: ?[16]u8!
-- parent_message_id: ?u64!
-- parent_part_id: ?u64!
-- source_id: ?[16]u8!
-- profile: []const u8!
-- model: []const u8!
-- reasoning: []const u8!
-- config_rev: u64!
-- max_rounds: ?u64!
-- title: []const u8!
-- agent: ?[]const u8!
-- name: ?[]const u8!
-- created_by_name: ?[]const u8!
-- created_by_version: ?[]const u8!
-- message_count: u64!
-- usage_input_total: u64!
-- usage_output_total: u64!
-- usage_reasoning_total: u64!
-- usage_cache_read_total: u64!
-- usage_cache_write_total: u64!
-- created_at_ms: u64!
-- updated_at_ms: u64!
-- open_run_id: ?u64!
-- open_run_kind: ?[]const u8!
-- open_run_started_at_ms: ?u64!
-- ctx_tokens_input: ?u64!
-- ctx_tokens_output: ?u64!
-- ctx_tokens_reasoning: ?u64!
-- ctx_tokens_cache_read: ?u64!
-- ctx_tokens_cache_write: ?u64!
SELECT
    id, root,
    origin, parent_id, parent_message_id, parent_part_id, source_id,
    profile, model, reasoning, config_rev, max_rounds, title, agent, name,
    created_by_name, created_by_version,
    message_count,
    usage_input_total, usage_output_total, usage_reasoning_total, usage_cache_read_total, usage_cache_write_total,
    created_at_ms, updated_at_ms,
    open_run_id, open_run_kind, open_run_started_at_ms,
    ctx_tokens_input, ctx_tokens_output, ctx_tokens_reasoning, ctx_tokens_cache_read, ctx_tokens_cache_write
FROM session_context
WHERE id = :id;

-- name: SetOpenRun :one
-- Set the terminal obligation for a newly started run. A live session has at most one open run.
-- id: [16]u8!
-- run_id: u64!
-- kind: []const u8!
-- started_at_ms: u64!
-- changed: i64!
UPDATE sessions SET
    open_run_id = :run_id,
    open_run_kind = :kind,
    open_run_started_at_ms = :started_at_ms
WHERE id = :id AND open_run_id IS NULL
RETURNING 1 AS changed;

-- name: ClearOpenRun :one
-- Clear only the run that the terminal event closes.
-- id: [16]u8!
-- run_id: u64!
-- kind: []const u8!
-- started_at_ms: u64!
-- changed: i64!
UPDATE sessions SET
    open_run_id = NULL,
    open_run_kind = NULL,
    open_run_started_at_ms = NULL
WHERE id = :id
  AND open_run_id = :run_id
  AND open_run_kind = :kind
  AND open_run_started_at_ms = :started_at_ms
RETURNING 1 AS changed;

-- These are the session.list page columns. Every variant selects them in the same order, so the store
-- maps each generated row to one PageRow.

-- name: SessionPageRecent :many
-- Return a newest-first page. sessions_by_recent supplies the order and the cursor seek.
-- The top_level value filters the scan and keeps roots and forks.
-- top_level: bool!
-- cursor_updated_at_ms: u64!
-- cursor_id: [16]u8!
-- limit: i64!
-- id: [16]u8!
-- root: []const u8!
-- origin: []const u8!
-- parent_id: ?[16]u8!
-- parent_message_id: ?u64!
-- parent_part_id: ?u64!
-- source_id: ?[16]u8!
-- profile: []const u8!
-- model: []const u8!
-- reasoning: []const u8!
-- config_rev: u64!
-- max_rounds: ?u64!
-- title: []const u8!
-- agent: ?[]const u8!
-- name: ?[]const u8!
-- created_by_name: ?[]const u8!
-- created_by_version: ?[]const u8!
-- message_count: u64!
-- usage_input_total: u64!
-- usage_output_total: u64!
-- usage_reasoning_total: u64!
-- usage_cache_read_total: u64!
-- usage_cache_write_total: u64!
-- created_at_ms: u64!
-- updated_at_ms: u64!
-- ctx_tokens_input: ?u64!
-- ctx_tokens_output: ?u64!
-- ctx_tokens_reasoning: ?u64!
-- ctx_tokens_cache_read: ?u64!
-- ctx_tokens_cache_write: ?u64!
SELECT
    id, root,
    origin, parent_id, parent_message_id, parent_part_id, source_id,
    profile, model, reasoning, config_rev, max_rounds, title, agent, name,
    created_by_name, created_by_version,
    message_count,
    usage_input_total, usage_output_total, usage_reasoning_total, usage_cache_read_total, usage_cache_write_total,
    created_at_ms, updated_at_ms,
    ctx_tokens_input, ctx_tokens_output, ctx_tokens_reasoning, ctx_tokens_cache_read, ctx_tokens_cache_write
FROM session_context
WHERE (NOT :top_level OR origin IN ('root', 'fork'))
  AND (updated_at_ms, id) < (:cursor_updated_at_ms, :cursor_id)
ORDER BY updated_at_ms DESC, id DESC
LIMIT :limit;


-- name: SessionPageParent :many
-- Return children of one session. A seek on sessions_by_parent serves the order; parent is more selective
-- filter_parent_id: [16]u8!
-- top_level: bool!
-- cursor_updated_at_ms: u64!
-- cursor_id: [16]u8!
-- limit: i64!
-- id: [16]u8!
-- root: []const u8!
-- origin: []const u8!
-- parent_id: ?[16]u8!
-- parent_message_id: ?u64!
-- parent_part_id: ?u64!
-- source_id: ?[16]u8!
-- profile: []const u8!
-- model: []const u8!
-- reasoning: []const u8!
-- config_rev: u64!
-- max_rounds: ?u64!
-- title: []const u8!
-- agent: ?[]const u8!
-- name: ?[]const u8!
-- created_by_name: ?[]const u8!
-- created_by_version: ?[]const u8!
-- message_count: u64!
-- usage_input_total: u64!
-- usage_output_total: u64!
-- usage_reasoning_total: u64!
-- usage_cache_read_total: u64!
-- usage_cache_write_total: u64!
-- created_at_ms: u64!
-- updated_at_ms: u64!
-- ctx_tokens_input: ?u64!
-- ctx_tokens_output: ?u64!
-- ctx_tokens_reasoning: ?u64!
-- ctx_tokens_cache_read: ?u64!
-- ctx_tokens_cache_write: ?u64!
SELECT
    id, root,
    origin, parent_id, parent_message_id, parent_part_id, source_id,
    profile, model, reasoning, config_rev, max_rounds, title, agent, name,
    created_by_name, created_by_version,
    message_count,
    usage_input_total, usage_output_total, usage_reasoning_total, usage_cache_read_total, usage_cache_write_total,
    created_at_ms, updated_at_ms,
    ctx_tokens_input, ctx_tokens_output, ctx_tokens_reasoning, ctx_tokens_cache_read, ctx_tokens_cache_write
FROM session_context
WHERE parent_id = :filter_parent_id
  AND (NOT :top_level OR origin IN ('root', 'fork'))
  AND (updated_at_ms, id) < (:cursor_updated_at_ms, :cursor_id)
ORDER BY updated_at_ms DESC, id DESC
LIMIT :limit;

-- name: SessionCountRecent :one
-- Count every session, with an optional top_level filter. Matches SessionPageRecent.
-- top_level: bool!
-- total: u64!
SELECT count(*) AS total FROM sessions
WHERE (NOT :top_level OR origin IN ('root', 'fork'));


-- name: SessionCountParent :one
-- Count children of one session. Matches SessionPageParent.
-- filter_parent_id: [16]u8!
-- top_level: bool!
-- total: u64!
SELECT count(*) AS total FROM sessions
WHERE parent_id = :filter_parent_id
  AND (NOT :top_level OR origin IN ('root', 'fork'));

-- name: InsertPrompt :exec
-- Create snapshots the system prompt. An absent row reads back as null.
-- session_id: [16]u8!
-- prompt: []const u8!
-- base_prompt: []const u8!
-- instructions: []const u8!
-- skills: []const u8!
-- child_policy: []const u8
-- environment: []const u8!
INSERT INTO session_prompts(session_id, prompt, base_prompt, instructions, skills, child_policy, environment)
VALUES (:session_id, :prompt, :base_prompt, :instructions, :skills, :child_policy, :environment);

-- name: UpdatePromptContext :exec
-- A reload replaces the two file-derived components and the composed prompt of one session.
-- session_id: [16]u8!
-- prompt: []const u8!
-- instructions: []const u8!
-- skills: []const u8!
UPDATE session_prompts SET prompt = :prompt, instructions = :instructions, skills = :skills
WHERE session_id = :session_id;

-- name: SelectPrompt :optional
-- Read the session's system prompt. An absent row reads back as null.
-- session_id: [16]u8!
-- prompt: []const u8!
SELECT prompt FROM session_prompts WHERE session_id = :session_id;

-- name: SelectBasePrompt :optional
-- session_id: [16]u8!
-- base_prompt: []const u8!
SELECT base_prompt FROM session_prompts WHERE session_id = :session_id;

-- name: DeleteSession :exec
-- Remove one session row. Each child table cascades. parent_id and source_id hold no key.
-- id: [16]u8!
DELETE FROM sessions WHERE id = :id;

-- name: SessionChildIds :many
-- List the sessions that one session spawned. A fork holds source_id and stays out.
-- parent_id: [16]u8!
-- id: [16]u8!
SELECT id FROM sessions WHERE parent_id = :parent_id ORDER BY id;

-- name: SessionRecoveryCandidates :many
-- Find work in this workspace without a resident pane.
-- root: []const u8!
-- id: [16]u8!
SELECT id FROM sessions
WHERE root = :root
  AND (open_run_id IS NOT NULL OR EXISTS (SELECT 1 FROM pending_inputs WHERE session_id = sessions.id))
ORDER BY created_at_ms, id;

-- name: ChildAdmissionCandidates :many
-- The events rowid is the durable FIFO order across one root tree.
-- parent_id: [16]u8!
-- id: [16]u8!
WITH RECURSIVE tree(id) AS (
    SELECT id FROM sessions WHERE parent_id = :parent_id
    UNION
    SELECT s.id FROM sessions s JOIN tree t ON s.parent_id = t.id
)
SELECT s.id FROM sessions s
    JOIN tree t ON t.id = s.id
    JOIN pending_inputs p ON p.session_id = s.id
    JOIN events e ON e.session_id = p.session_id AND e.seq = p.seq
GROUP BY s.id ORDER BY min(e.rowid);

-- name: ChildByName :optional
-- parent_id: [16]u8!
-- name: []const u8!
-- id: [16]u8!
SELECT id FROM sessions WHERE parent_id = :parent_id AND name = :name;

-- name: SelectPromptParts :optional
-- session_id: [16]u8!
-- base_prompt: []const u8!
-- instructions: []const u8!
-- skills: []const u8!
-- child_policy: []const u8
-- environment: []const u8!
SELECT base_prompt, instructions, skills, child_policy, environment FROM session_prompts WHERE session_id = :session_id;

-- name: DeleteInstructions :exec
-- session_id: [16]u8!
DELETE FROM session_instructions WHERE session_id = :session_id;

-- name: InsertSkill :exec
-- session_id: [16]u8!
-- name: []const u8!
-- description: []const u8!
-- scope: []const u8!
-- path: []const u8!
-- canonical_path: []const u8!
INSERT INTO session_skills(session_id, name, description, scope, path, canonical_path)
VALUES (:session_id, :name, :description, :scope, :path, :canonical_path);

-- name: SelectSkills :many
-- session_id: [16]u8!
-- name: []const u8!
-- description: []const u8!
-- scope: []const u8!
-- path: []const u8!
-- canonical_path: []const u8!
SELECT name, description, scope, path, canonical_path FROM session_skills
WHERE session_id = :session_id ORDER BY name;

-- name: SelectSkill :optional
-- session_id: [16]u8!
-- name: []const u8!
-- description: []const u8!
-- scope: []const u8!
-- path: []const u8!
-- canonical_path: []const u8!
SELECT name, description, scope, path, canonical_path FROM session_skills
WHERE session_id = :session_id AND name = :name;

-- name: SessionHasSkills :optional
-- session_id: [16]u8!
-- present: i64!
SELECT 1 AS present FROM session_skills WHERE session_id = :session_id LIMIT 1;

-- name: DeleteSkills :exec
-- session_id: [16]u8!
DELETE FROM session_skills WHERE session_id = :session_id;

-- name: InsertInstruction :exec
-- session_id: [16]u8!
-- scope: []const u8!
-- path: []const u8!
-- canonical_path: []const u8!
-- content_hash: [32]u8!
-- text: []const u8!
INSERT INTO session_instructions(session_id, scope, path, canonical_path, content_hash, text)
VALUES (:session_id, :scope, :path, :canonical_path, :content_hash, :text);

-- name: SelectInstructions :many
-- session_id: [16]u8!
-- scope: []const u8!
-- path: []const u8!
-- canonical_path: []const u8!
-- content_hash: [32]u8!
-- text: []const u8!
SELECT scope, path, canonical_path, content_hash, text FROM session_instructions
WHERE session_id = :session_id ORDER BY scope;

-- name: SelectInstructionSources :many
-- session_id: [16]u8!
-- scope: []const u8!
-- path: []const u8!
-- canonical_path: []const u8!
-- content_hash: [32]u8!
SELECT scope, path, canonical_path, content_hash FROM session_instructions
WHERE session_id = :session_id ORDER BY scope;
