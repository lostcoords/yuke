-- The queries of the sessions table.

--! insert_session (id: [u8; 16], prompt: String, settings: String)
INSERT INTO sessions(id, prompt, settings) VALUES (:id, :prompt, :settings);

--! copy_session (source: [u8; 16], id: [u8; 16], cut: u64)
--- Add session `id` as a fork of session `source`: its prompt, its preview, and its newest settings at event
--- `cut`. It adds no row for an unknown source.
INSERT INTO sessions(id, prompt, settings, preview, fork_of)
SELECT
    :id, prompt,
    coalesce(
        (SELECT settings FROM events WHERE session_id = :source AND kind = 'settings' AND seq <= :cut
         ORDER BY seq DESC LIMIT 1),
        settings
    ),
    preview, id
FROM sessions WHERE id = :source;

--! set_session_settings (id: [u8; 16], settings: String)
--- Keep `settings`, the settings of the newest settings event, in the row of the session.
UPDATE sessions SET settings = :settings WHERE id = :id;

--! touch_session (id: [u8; 16])
--- Give the session the time and the id of its newest event.
UPDATE sessions
SET (updated_at, newest_event) = (
    SELECT created_at, id FROM events WHERE session_id = :id ORDER BY seq DESC LIMIT 1
)
WHERE id = :id;

--! place_fork (id: [u8; 16])
--- Give a new fork the id of its newest event row. Its copied events keep their times, so its updated time
--- stays its creation time.
UPDATE sessions
SET newest_event = (SELECT id FROM events WHERE session_id = :id ORDER BY seq DESC LIMIT 1)
WHERE id = :id;

--! set_preview (id: [u8; 16], preview: &str)
--- Give the session the preview `preview` when it has none.
UPDATE sessions SET preview = :preview WHERE id = :id AND preview IS NULL;

--! list_sessions (before: i64, limit: usize) : (id: [u8; 16], settings: crate::Json<yuke_protocol::SessionSettings>, preview?, fork_of?: [u8; 16], created_at: u64, updated_at: u64, newest_event: i64)
--- The sessions whose newest event id is below `before`, newest first.
SELECT id, settings, preview, fork_of, created_at, updated_at, newest_event FROM sessions
WHERE newest_event < :before
ORDER BY newest_event DESC
LIMIT :limit;

--! list_sessions_in (cwd: &str, before: i64, limit: usize) : (id: [u8; 16], settings: crate::Json<yuke_protocol::SessionSettings>, preview?, fork_of?: [u8; 16], created_at: u64, updated_at: u64, newest_event: i64)
--- The sessions of the folder `cwd` whose newest event id is below `before`, newest first.
SELECT id, settings, preview, fork_of, created_at, updated_at, newest_event FROM sessions
WHERE cwd = :cwd AND newest_event < :before
ORDER BY newest_event DESC
LIMIT :limit;

--! session_summary (id: [u8; 16]) : (id: [u8; 16], settings: crate::Json<yuke_protocol::SessionSettings>, preview?, fork_of?: [u8; 16], created_at: u64, updated_at: u64)
--- The saved facts for `session/list` and `session/get`. It returns no row for an unknown session.
SELECT id, settings, preview, fork_of, created_at, updated_at FROM sessions WHERE id = :id;

--! session_prompt (id: [u8; 16]) : (prompt: crate::Json<Vec<yuke_agent::PromptSection>>)
--- The sections of the system prompt of the session. It returns no row for an unknown session.
SELECT prompt FROM sessions WHERE id = :id;

--! session_exists (id: [u8; 16]) : (present: bool)
--- Whether a session has this id.
SELECT EXISTS(SELECT 1 FROM sessions WHERE id = :id) AS present;

--! delete_session (id: [u8; 16])
--- Delete the session. The cascade deletes its events and its pending inputs.
DELETE FROM sessions WHERE id = :id;
