-- Rebuild the two durable tables with storage-class, identity-width, and numeric
-- range checks. Reads still validate: files can be damaged or edited externally.

CREATE TABLE events_checked (
    session_id BLOB NOT NULL
        CHECK (typeof(session_id) = 'blob' AND length(session_id) = 16),
    seq INTEGER NOT NULL
        CHECK (typeof(seq) = 'integer' AND seq BETWEEN 1 AND 9007199254740991),
    name TEXT NOT NULL
        CHECK (typeof(name) = 'text' AND length(name) > 0),
    payload TEXT NOT NULL
        CHECK (typeof(payload) = 'text' AND length(payload) > 0),
    PRIMARY KEY (session_id, seq)
) WITHOUT ROWID;

INSERT INTO events_checked(session_id, seq, name, payload)
    SELECT session_id, seq, name, payload FROM events;

DROP TABLE events;
ALTER TABLE events_checked RENAME TO events;

CREATE TABLE session_meta_checked (
    session_id BLOB PRIMARY KEY
        CHECK (typeof(session_id) = 'blob' AND length(session_id) = 16),
    seq_high INTEGER NOT NULL DEFAULT 0
        CHECK (typeof(seq_high) = 'integer' AND seq_high BETWEEN 0 AND 9007199254740991),
    message_id_high INTEGER NOT NULL DEFAULT 0
        CHECK (typeof(message_id_high) = 'integer' AND message_id_high BETWEEN 0 AND 9007199254740991),
    run_id_high INTEGER NOT NULL DEFAULT 0
        CHECK (typeof(run_id_high) = 'integer' AND run_id_high BETWEEN 0 AND 9007199254740991),
    input_id_high INTEGER NOT NULL DEFAULT 0
        CHECK (typeof(input_id_high) = 'integer' AND input_id_high BETWEEN 0 AND 9007199254740991),
    config_rev_high INTEGER NOT NULL DEFAULT 0
        CHECK (typeof(config_rev_high) = 'integer' AND config_rev_high BETWEEN 0 AND 9007199254740991)
) WITHOUT ROWID;

INSERT INTO session_meta_checked(
    session_id,
    seq_high,
    message_id_high,
    run_id_high,
    input_id_high,
    config_rev_high
)
    SELECT
        session_id,
        seq_high,
        message_id_high,
        run_id_high,
        input_id_high,
        config_rev_high
    FROM session_meta;

DROP TABLE session_meta;
ALTER TABLE session_meta_checked RENAME TO session_meta;
