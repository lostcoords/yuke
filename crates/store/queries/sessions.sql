-- The queries of the sessions table.

--! insert_session (id: [u8; 16])
INSERT INTO sessions(id) VALUES (:id);

--! session_count (id: [u8; 16]) : (count: i64)
--- The number of sessions with this id: 0 or 1.
SELECT count(*) AS count FROM sessions WHERE id = :id;

--! delete_session (id: [u8; 16])
--- Delete the session. The cascade deletes its events and its pending inputs.
DELETE FROM sessions WHERE id = :id;
