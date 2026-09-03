-- Durable pending inputs point to their input.queued event.
CREATE TABLE pending_inputs (
    session_id   BLOB NOT NULL CHECK (length(session_id) = 16)
        REFERENCES sessions(id) ON DELETE CASCADE,
    input_id     INTEGER NOT NULL CHECK (input_id BETWEEN 1 AND 9007199254740991),
    seq          INTEGER NOT NULL CHECK (seq BETWEEN 1 AND 9007199254740991),
    queued_at_ms INTEGER NOT NULL CHECK (queued_at_ms BETWEEN 0 AND 9007199254740991),
    payload      TEXT NOT NULL CHECK (length(payload) > 0),

    PRIMARY KEY (session_id, input_id),
    UNIQUE (session_id, seq),
    FOREIGN KEY (session_id, seq) REFERENCES events(session_id, seq) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
