-- name: InsertBlobRef :exec
-- Insert one reference for a session and blob. The size supports a later budget pass.
-- session_id: [16]u8!
-- hash: [32]u8!
-- bytes: u64!
INSERT OR IGNORE INTO blob_refs(session_id, hash, bytes) VALUES (:session_id, :hash, :bytes);

-- name: BlobRefsOfSession :many
-- List the blobs that one session names.
-- session_id: [16]u8!
-- hash: [32]u8!
SELECT hash FROM blob_refs WHERE session_id = :session_id;

-- name: BlobReferenced :optional
-- Report whether any session names the blob.
-- hash: [32]u8!
-- named: u64!
SELECT 1 AS named FROM blob_refs WHERE hash = :hash LIMIT 1;
