-- The queries of the sessions table.

--! insert_session (id: [u8; 16], prompt: String, settings: String, parent?: [u8; 16])
INSERT INTO sessions(id, prompt, settings, parent) VALUES (:id, :prompt, :settings, :parent);

--! copy_session (source: [u8; 16], id: [u8; 16], cut: u64, title?: String)
--- Add session `id` as a fork of session `source`: its prompt, the title `title`, and its newest settings at event
--- `cut`. It adds no row for an unknown source.
INSERT INTO sessions(id, prompt, settings, title, fork_of)
SELECT
    :id, prompt,
    coalesce(
        (SELECT settings FROM events WHERE session_id = :source AND kind = 'settings' AND seq <= :cut
         ORDER BY seq DESC LIMIT 1),
        settings
    ),
    :title, id
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

--! initialize_title (id: [u8; 16], title: &str)
--- Give the session the title `title` when it has none.
UPDATE sessions SET title = :title WHERE id = :id AND title IS NULL;

--! rename_session (id: [u8; 16], title: &str)
--- Rename the session without changing its events or activity times.
UPDATE sessions SET title = :title WHERE id = :id;

--! list_sessions (parent?: [u8; 16], cwd?: &str, before: i64, limit: usize) : (id: [u8; 16], settings: crate::Json<yuke_protocol::SessionSettings>, title?, fork_of?: [u8; 16], parent?: [u8; 16], created_at: u64, updated_at: u64, newest_event: i64)
--- The sessions of `parent`, or without a parent, whose newest event id is below `before`, newest first. With `cwd`,
--- only the sessions of that folder.
SELECT id, settings, title, fork_of, parent, created_at, updated_at, newest_event FROM sessions
WHERE parent IS :parent AND (:cwd IS NULL OR cwd = :cwd) AND newest_event < :before
ORDER BY newest_event DESC
LIMIT :limit;

--! session_summary (id: [u8; 16]) : (id: [u8; 16], settings: crate::Json<yuke_protocol::SessionSettings>, title?, fork_of?: [u8; 16], parent?: [u8; 16], created_at: u64, updated_at: u64)
--- The saved facts for `session/list` and `session/get`. It returns no row for an unknown session.
SELECT id, settings, title, fork_of, parent, created_at, updated_at FROM sessions WHERE id = :id;

--! session_context (id: [u8; 16]) : (settings: crate::Json<yuke_protocol::SessionSettings>, prompt: crate::Json<Vec<yuke_agent::PromptSection>>, parent?: [u8; 16])
--- The settings, prompt sections, and parent of the session. It returns no row for an unknown session.
SELECT settings, prompt, parent FROM sessions WHERE id = :id;

--! session_exists (id: [u8; 16]) : (present: bool)
--- Whether a session has this id.
SELECT EXISTS(SELECT 1 FROM sessions WHERE id = :id) AS present;

--! delete_session (id: [u8; 16])
--- Delete the session. The cascade deletes its events and its pending inputs.
DELETE FROM sessions WHERE id = :id;
