-- name: InsertSession :exec
-- The insert omits counters, usage totals, high-water marks, and open-run fields.
-- id: [16]u8!
-- workspace_id: [16]u8!
-- origin: []const u8!
-- parent_id: ?[16]u8!
-- parent_message_id: ?u64!
-- parent_part_id: ?u64!
-- source_id: ?[16]u8!
-- profile: []const u8!
-- model: []const u8!
-- reasoning: []const u8!
-- config_rev: u64!
-- permission: []const u8!
-- max_rounds: ?u64!
-- title: []const u8!
-- agent: ?[]const u8!
-- created_by_name: ?[]const u8!
-- created_by_version: ?[]const u8!
-- created_at_ms: u64!
-- updated_at_ms: u64!
INSERT INTO sessions(
    id, workspace_id, origin, parent_id, parent_message_id, parent_part_id, source_id,
    profile, model, reasoning, config_rev, permission, max_rounds, title, agent,
    created_by_name, created_by_version, created_at_ms, updated_at_ms
) VALUES (
    :id, :workspace_id, :origin, :parent_id, :parent_message_id, :parent_part_id, :source_id,
    :profile, :model, :reasoning, :config_rev, :permission, :max_rounds, :title, :agent,
    :created_by_name, :created_by_version, :created_at_ms, :updated_at_ms
);

-- name: SessionExists :optional
-- id: [16]u8!
-- present: i64!
SELECT 1 AS present FROM sessions WHERE id = :id;

-- name: SessionSnapshot :optional
-- Return the client-facing summary and the open-run recovery marker for one id.
-- Omit the id allocation marks because recovery reads them separately.
-- id: [16]u8!
-- workspace_id: [16]u8!
-- origin: []const u8!
-- parent_id: ?[16]u8!
-- parent_message_id: ?u64!
-- parent_part_id: ?u64!
-- source_id: ?[16]u8!
-- profile: []const u8!
-- model: []const u8!
-- reasoning: []const u8!
-- config_rev: u64!
-- permission: []const u8!
-- max_rounds: ?u64!
-- title: []const u8!
-- agent: ?[]const u8!
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
SELECT
    id, workspace_id,
    origin, parent_id, parent_message_id, parent_part_id, source_id,
    profile, model, reasoning, config_rev, permission, max_rounds, title, agent,
    created_by_name, created_by_version,
    message_count,
    usage_input_total, usage_output_total, usage_reasoning_total, usage_cache_read_total, usage_cache_write_total,
    created_at_ms, updated_at_ms,
    open_run_id, open_run_kind, open_run_started_at_ms
FROM sessions
WHERE id = :id;

-- The session.list page columns. Every page variant selects this same set in this same order, so
-- the store maps each generated row to one PageRow.

-- name: SessionPageRecent :many
-- Newest-first page over every workspace. sessions_by_recent supplies the order and the cursor seek.
-- top_level applies during the scan and keeps roots and forks.
-- top_level: bool!
-- cursor_updated_at_ms: u64!
-- cursor_id: [16]u8!
-- limit: i64!
-- id: [16]u8!
-- workspace_id: [16]u8!
-- origin: []const u8!
-- parent_id: ?[16]u8!
-- parent_message_id: ?u64!
-- parent_part_id: ?u64!
-- source_id: ?[16]u8!
-- profile: []const u8!
-- model: []const u8!
-- reasoning: []const u8!
-- config_rev: u64!
-- permission: []const u8!
-- max_rounds: ?u64!
-- title: []const u8!
-- agent: ?[]const u8!
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
SELECT
    id, workspace_id,
    origin, parent_id, parent_message_id, parent_part_id, source_id,
    profile, model, reasoning, config_rev, permission, max_rounds, title, agent,
    created_by_name, created_by_version,
    message_count,
    usage_input_total, usage_output_total, usage_reasoning_total, usage_cache_read_total, usage_cache_write_total,
    created_at_ms, updated_at_ms
FROM sessions
WHERE (NOT :top_level OR origin IN ('root', 'fork'))
  AND (updated_at_ms, id) < (:cursor_updated_at_ms, :cursor_id)
ORDER BY updated_at_ms DESC, id DESC
LIMIT :limit;

-- name: SessionPageWorkspace :many
-- Same page inside one workspace. A seek on sessions_by_workspace serves the filter and order.
-- top_level refines the population. A parent filter dispatches to SessionPageParent instead.
-- filter_workspace_id: [16]u8!
-- top_level: bool!
-- cursor_updated_at_ms: u64!
-- cursor_id: [16]u8!
-- limit: i64!
-- id: [16]u8!
-- workspace_id: [16]u8!
-- origin: []const u8!
-- parent_id: ?[16]u8!
-- parent_message_id: ?u64!
-- parent_part_id: ?u64!
-- source_id: ?[16]u8!
-- profile: []const u8!
-- model: []const u8!
-- reasoning: []const u8!
-- config_rev: u64!
-- permission: []const u8!
-- max_rounds: ?u64!
-- title: []const u8!
-- agent: ?[]const u8!
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
SELECT
    id, workspace_id,
    origin, parent_id, parent_message_id, parent_part_id, source_id,
    profile, model, reasoning, config_rev, permission, max_rounds, title, agent,
    created_by_name, created_by_version,
    message_count,
    usage_input_total, usage_output_total, usage_reasoning_total, usage_cache_read_total, usage_cache_write_total,
    created_at_ms, updated_at_ms
FROM sessions
WHERE workspace_id = :filter_workspace_id
  AND (NOT :top_level OR origin IN ('root', 'fork'))
  AND (updated_at_ms, id) < (:cursor_updated_at_ms, :cursor_id)
ORDER BY updated_at_ms DESC, id DESC
LIMIT :limit;

-- name: SessionPageParent :many
-- Children of one session. A seek on sessions_by_parent serves the order; parent is more selective
-- than workspace, so a workspace scope becomes a post-filter here.
-- filter_parent_id: [16]u8!
-- filter_workspace_id: ?[16]u8!
-- top_level: bool!
-- cursor_updated_at_ms: u64!
-- cursor_id: [16]u8!
-- limit: i64!
-- id: [16]u8!
-- workspace_id: [16]u8!
-- origin: []const u8!
-- parent_id: ?[16]u8!
-- parent_message_id: ?u64!
-- parent_part_id: ?u64!
-- source_id: ?[16]u8!
-- profile: []const u8!
-- model: []const u8!
-- reasoning: []const u8!
-- config_rev: u64!
-- permission: []const u8!
-- max_rounds: ?u64!
-- title: []const u8!
-- agent: ?[]const u8!
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
SELECT
    id, workspace_id,
    origin, parent_id, parent_message_id, parent_part_id, source_id,
    profile, model, reasoning, config_rev, permission, max_rounds, title, agent,
    created_by_name, created_by_version,
    message_count,
    usage_input_total, usage_output_total, usage_reasoning_total, usage_cache_read_total, usage_cache_write_total,
    created_at_ms, updated_at_ms
FROM sessions
WHERE parent_id = :filter_parent_id
  AND (:filter_workspace_id IS NULL OR workspace_id = :filter_workspace_id)
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

-- name: SessionCountWorkspace :one
-- Count sessions in one workspace. Matches SessionPageWorkspace.
-- filter_workspace_id: [16]u8!
-- top_level: bool!
-- total: u64!
SELECT count(*) AS total FROM sessions
WHERE workspace_id = :filter_workspace_id
  AND (NOT :top_level OR origin IN ('root', 'fork'));

-- name: SessionCountParent :one
-- Count children of one session. Matches SessionPageParent.
-- filter_parent_id: [16]u8!
-- filter_workspace_id: ?[16]u8!
-- top_level: bool!
-- total: u64!
SELECT count(*) AS total FROM sessions
WHERE parent_id = :filter_parent_id
  AND (:filter_workspace_id IS NULL OR workspace_id = :filter_workspace_id)
  AND (NOT :top_level OR origin IN ('root', 'fork'));

-- name: InsertPrompt :exec
-- The system prompt is snapshotted at creation. A missing row reads back as null.
-- session_id: [16]u8!
-- prompt: []const u8!
INSERT INTO session_prompts(session_id, prompt) VALUES (:session_id, :prompt);
