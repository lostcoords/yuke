-- name: InsertSession :exec
-- The insert omits counters, usage totals, high-water marks, and open-run fields.
-- id: [16]u8!
-- workspace_id: [16]u8!
-- origin: []const u8!
-- parent_id: ?[16]u8!
-- parent_message_id: ?u64!
-- parent_part_id: ?u64!
-- source_id: ?[16]u8!
-- job_id: ?[16]u8!
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
    id, workspace_id, origin, parent_id, parent_message_id, parent_part_id, source_id, job_id,
    profile, model, reasoning, config_rev, permission, max_rounds, title, agent,
    created_by_name, created_by_version, created_at_ms, updated_at_ms
) VALUES (
    :id, :workspace_id, :origin, :parent_id, :parent_message_id, :parent_part_id, :source_id, :job_id,
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
-- job_id: ?[16]u8!
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
    origin, parent_id, parent_message_id, parent_part_id, source_id, job_id,
    profile, model, reasoning, config_rev, permission, max_rounds, title, agent,
    created_by_name, created_by_version,
    message_count,
    usage_input_total, usage_output_total, usage_reasoning_total, usage_cache_read_total, usage_cache_write_total,
    created_at_ms, updated_at_ms,
    open_run_id, open_run_kind, open_run_started_at_ms
FROM sessions
WHERE id = :id;

-- name: SessionPage :many
-- One keyset page of the session list, newest first. Optional filters select the population:
-- top_level, one parent, or one job. The id tiebreak keeps the page stable.
-- filter_workspace_id: ?[16]u8!
-- filter_parent_id: ?[16]u8!
-- filter_job_id: ?[16]u8!
-- top_level: bool!
-- cursor_updated_at_ms: ?u64!
-- cursor_id: ?[16]u8!
-- limit: i64!
-- id: [16]u8!
-- workspace_id: [16]u8!
-- origin: []const u8!
-- parent_id: ?[16]u8!
-- parent_message_id: ?u64!
-- parent_part_id: ?u64!
-- source_id: ?[16]u8!
-- job_id: ?[16]u8!
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
    origin, parent_id, parent_message_id, parent_part_id, source_id, job_id,
    profile, model, reasoning, config_rev, permission, max_rounds, title, agent,
    created_by_name, created_by_version,
    message_count,
    usage_input_total, usage_output_total, usage_reasoning_total, usage_cache_read_total, usage_cache_write_total,
    created_at_ms, updated_at_ms
FROM sessions
WHERE (:filter_workspace_id IS NULL OR workspace_id = :filter_workspace_id)
  AND (:filter_parent_id     IS NULL OR parent_id    = :filter_parent_id)
  AND (:filter_job_id        IS NULL OR job_id        = :filter_job_id)
  AND (NOT :top_level OR origin IN ('root', 'fork'))
  AND (:cursor_updated_at_ms IS NULL
       OR updated_at_ms < :cursor_updated_at_ms
       OR (updated_at_ms = :cursor_updated_at_ms AND id < :cursor_id))
ORDER BY updated_at_ms DESC, id DESC
LIMIT :limit;

-- name: SessionCount :one
-- Return the size of the full view that the selector describes. The selector matches SessionPage.
-- filter_workspace_id: ?[16]u8!
-- filter_parent_id: ?[16]u8!
-- filter_job_id: ?[16]u8!
-- top_level: bool!
-- total: u64!
SELECT count(*) AS total FROM sessions
WHERE (:filter_workspace_id IS NULL OR workspace_id = :filter_workspace_id)
  AND (:filter_parent_id     IS NULL OR parent_id    = :filter_parent_id)
  AND (:filter_job_id        IS NULL OR job_id        = :filter_job_id)
  AND (NOT :top_level OR origin IN ('root', 'fork'));

-- name: InsertPrompt :exec
-- The system prompt is snapshotted at creation. A missing row reads back as null.
-- session_id: [16]u8!
-- prompt: []const u8!
INSERT INTO session_prompts(session_id, prompt) VALUES (:session_id, :prompt);
