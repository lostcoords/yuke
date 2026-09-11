-- Each session names the blobs in its inputs. A removal can unlink a blob no session names.
CREATE TABLE blob_refs (
    session_id BLOB NOT NULL CHECK (length(session_id) = 16)
        REFERENCES sessions(id) ON DELETE CASCADE,
    hash       BLOB NOT NULL CHECK (length(hash) = 32),
    bytes      INTEGER NOT NULL CHECK (bytes BETWEEN 0 AND 9007199254740991),

    PRIMARY KEY (session_id, hash)
) STRICT, WITHOUT ROWID;
CREATE INDEX blob_refs_hash ON blob_refs(hash);
