-- The queries of the sessions table.

--! insert_session (id: [u8; 16], settings: String)
INSERT INTO sessions(id, settings) VALUES (:id, :settings);

--! update_settings (id: [u8; 16], settings: String)
--- Replace the settings of the session. It changes no row for an unknown session.
UPDATE sessions SET settings = :settings WHERE id = :id;

--! session_settings (id: [u8; 16]) : (settings: Json<yuke_agent::SessionSettings>)
SELECT settings FROM sessions WHERE id = :id;

--! session_count (id: [u8; 16]) : (count: i64)
--- The number of sessions with this id: 0 or 1.
SELECT count(*) AS count FROM sessions WHERE id = :id;

--! delete_session (id: [u8; 16])
--- Delete the session. The cascade deletes its commits and its pending inputs.
DELETE FROM sessions WHERE id = :id;
