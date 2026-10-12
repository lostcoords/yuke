-- Three tables: the sessions, the numbered events of each session, and the inputs that no commit consumed. Content
-- that only yuke reads back is JSON. Facts that a query can ask about are columns.

CREATE TABLE sessions (
    id BLOB PRIMARY KEY NOT NULL,          -- 16 bytes of a version 7 UUID, so new rows go near the end of the key
    last_seq INTEGER NOT NULL DEFAULT 0,   -- the number of the newest event of the session
    created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)) -- Unix milliseconds
) STRICT;

CREATE TABLE events (                      -- the commits and the settings of each session, numbered 1, 2, 3, and so on
    session_id BLOB NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    seq INTEGER NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('commit', 'settings')),
    blocks TEXT,                           -- JSON blocks that a commit adds
    settings TEXT,                         -- JSON SessionSettings of a settings event
    consumed TEXT,                         -- JSON ids of the inputs that a commit consumed
    head TEXT,                             -- JSON blocks that start the context after a replacement
    keep INTEGER,                          -- set with head: the number of earlier blocks that stay after head
    model TEXT,                            -- the origin of an answer
    base_url TEXT,                         -- set with model
    input_tokens INTEGER,                  -- the usage of an answer, set with model
    output_tokens INTEGER,
    reasoning_tokens INTEGER,
    cache_read_tokens INTEGER,
    cache_write_tokens INTEGER,
    finish_reason TEXT,                    -- FinishReason::as_str() of an answer, set with model
    end_kind TEXT,                         -- completed | stopped | cancelled | failed; set on the end commit
    end_finish_reason TEXT,                -- FinishReason::as_str(), set only with end_kind = 'completed'
    end_message TEXT,                      -- the text of the error, set only with end_kind = 'failed'
    created_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER)),
    PRIMARY KEY (session_id, seq),
    CHECK ((end_kind IS 'completed') = (end_finish_reason IS NOT NULL)),
    CHECK ((end_kind IS 'failed') = (end_message IS NOT NULL))
) STRICT;
CREATE INDEX events_replace ON events(session_id, seq) WHERE keep IS NOT NULL;

CREATE TABLE pending_inputs (              -- the inputs that no commit consumed
    id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, -- AUTOINCREMENT never gives the id of a deleted input again
    session_id BLOB NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    blocks TEXT NOT NULL,                  -- JSON blocks
    accepted_at INTEGER NOT NULL DEFAULT (CAST(unixepoch('subsec') * 1000 AS INTEGER))
) STRICT;
