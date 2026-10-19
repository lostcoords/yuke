-- The queries of the sessions table.

--! insert_session (id: [u8; 16], prompt: String)
INSERT INTO sessions(id, prompt) VALUES (:id, :prompt);

--! copy_session (source: [u8; 16], id: [u8; 16])
--- Add session `id` with the prompt of session `source`. It adds no row for an unknown source.
INSERT INTO sessions(id, prompt) SELECT :id, prompt FROM sessions WHERE id = :source;

--! session_prompt (id: [u8; 16]) : (prompt: String)
--- The system prompt of the session. It returns no row for an unknown session.
SELECT prompt FROM sessions WHERE id = :id;

--! session_count (id: [u8; 16]) : (count: i64)
--- The number of sessions with this id: 0 or 1.
SELECT count(*) AS count FROM sessions WHERE id = :id;

--! delete_session (id: [u8; 16])
--- Delete the session. The cascade deletes its events and its pending inputs.
DELETE FROM sessions WHERE id = :id;
