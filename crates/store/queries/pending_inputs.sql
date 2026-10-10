-- The queries of the pending inputs: the inputs that no commit consumed.

--! insert_pending_input (session_id: [u8; 16], blocks: String) : (id: i64)
--- Add a pending input to the session, and return its id. It adds no row for an unknown session.
INSERT INTO pending_inputs(session_id, blocks)
SELECT id, :blocks FROM sessions WHERE id = :session_id
RETURNING id;

--! pending_inputs (session_id: [u8; 16]) : (id, blocks: Json<Vec<yuke_ai::Block>>)
SELECT id, blocks FROM pending_inputs WHERE session_id = :session_id ORDER BY id;

--! delete_pending_input (session_id: [u8; 16], id: i64)
DELETE FROM pending_inputs WHERE session_id = :session_id AND id = :id;
