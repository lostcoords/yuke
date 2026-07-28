-- The event log of record, plus the per-session high-water marks recovered at
-- daemon start. Shipped migration text is immutable: add a step, never edit one.

CREATE TABLE events (
    session_id BLOB NOT NULL,    -- 16-byte Session_Id
    seq        INTEGER NOT NULL, -- per-session Seq, contiguous from 1
    name       TEXT NOT NULL,    -- broadcast wire name, for filtered reads
    payload    TEXT NOT NULL,    -- wire JSON verbatim; the codec is authoritative
    PRIMARY KEY (session_id, seq)
) WITHOUT ROWID;

-- Id recovery reads these, never MAX(seq) over events: a truncating rewind
-- deletes the tail and max-row recovery would reclaim ids.
CREATE TABLE session_meta (
    session_id      BLOB PRIMARY KEY,
    seq_high        INTEGER NOT NULL DEFAULT 0,
    message_id_high INTEGER NOT NULL DEFAULT 0,
    run_id_high     INTEGER NOT NULL DEFAULT 0,
    input_id_high   INTEGER NOT NULL DEFAULT 0,
    config_rev_high INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;
