-- The queries of the sessions table.

--! insert_session (id: [u8; 16])
INSERT INTO sessions(id) VALUES (:id);

--! insert_fork (id: [u8; 16], cut: u64)
--- Add session `id` of a fork, with `cut` as its newest event number.
INSERT INTO sessions(id, last_seq) VALUES (:id, :cut);

--! take_seq (id: [u8; 16])
--- Take the next event number of the session. It changes no row for an unknown session.
UPDATE sessions SET last_seq = last_seq + 1 WHERE id = :id;

--! session_count (id: [u8; 16]) : (count: i64)
--- The number of sessions with this id: 0 or 1.
SELECT count(*) AS count FROM sessions WHERE id = :id;

--! delete_session (id: [u8; 16])
--- Delete the session. The cascade deletes its events and its pending inputs.
DELETE FROM sessions WHERE id = :id;
