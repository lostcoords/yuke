-- The queries of the sessions table.

--! insert_session (id: [u8; 16], prompt: String)
INSERT INTO sessions(id, prompt) VALUES (:id, :prompt);

--! copy_session (source: [u8; 16], id: [u8; 16])
--- Add session `id` with the prompt of session `source`. It adds no row for an unknown source.
INSERT INTO sessions(id, prompt) SELECT :id, prompt FROM sessions WHERE id = :source;

--! session_prompt (id: [u8; 16]) : (prompt: crate::Json<Vec<yuke_agent::PromptSection>>)
--- The sections of the system prompt of the session. It returns no row for an unknown session.
SELECT prompt FROM sessions WHERE id = :id;

--! session_exists (id: [u8; 16]) : (present: bool)
--- Whether a session has this id.
SELECT EXISTS(SELECT 1 FROM sessions WHERE id = :id) AS present;

--! delete_session (id: [u8; 16])
--- Delete the session. The cascade deletes its events and its pending inputs.
DELETE FROM sessions WHERE id = :id;
