-- The queries of the commits table: one row for each engine commit.

--! insert_commit (session_id: [u8; 16], head?: String, keep?: usize, blocks: String, model?: String, base_url?: String, input_tokens?: u64, output_tokens?: u64, reasoning_tokens?: u64, cache_read_tokens?: u64, cache_write_tokens?: u64, finish_reason?: String, end_kind?: String, end_finish_reason?: String, end_message?: String)
--- Add a commit after the commits of the session. It adds no row for an unknown session.
INSERT INTO commits(
    session_id, head, keep, blocks, model, base_url, input_tokens, output_tokens, reasoning_tokens,
    cache_read_tokens, cache_write_tokens, finish_reason, end_kind, end_finish_reason, end_message
)
SELECT
    id, :head, :keep, :blocks, :model, :base_url, :input_tokens, :output_tokens, :reasoning_tokens,
    :cache_read_tokens, :cache_write_tokens, :finish_reason, :end_kind, :end_finish_reason, :end_message
FROM sessions WHERE id = :session_id;

--! newest_replacement (session_id: [u8; 16]) : (id, head?: Json<Vec<yuke_ai::Block>>, keep?: usize)
--- The newest commit of the session with a replacement.
SELECT id, head, keep FROM commits
WHERE session_id = :session_id AND keep IS NOT NULL
ORDER BY id DESC LIMIT 1;

--! previous_commit (session_id: [u8; 16], before: i64) : (id, head?: Json<Vec<yuke_ai::Block>>, keep?: usize, blocks: Json<Vec<yuke_ai::Block>>)
--- The newest commit of the session before commit `before`.
SELECT id, head, keep, blocks FROM commits
WHERE session_id = :session_id AND id < :before
ORDER BY id DESC LIMIT 1;

--! commits_from (session_id: [u8; 16], first: i64) : (blocks: Json<Vec<yuke_ai::Block>>, end_kind?)
--- The commits of the session from commit `first` on, oldest first.
SELECT blocks, end_kind FROM commits
WHERE session_id = :session_id AND id >= :first
ORDER BY id;
