-- The schema has mutable registry tables and an append-only activity log. Projections rebuild from the log.
-- STRICT types enforce storage; checks enforce domain rules; 2^53-1 keeps numbers safe for wire JSON.

-- The session registry holds primary state. The log does not derive this state. A rowid table suits this
-- wide, often updated row. Flatten Session_Origin; each arm's ids are non-null only for that arm.
CREATE TABLE sessions (
    id           BLOB NOT NULL UNIQUE CHECK (length(id) = 16), -- proto.SessionId; UUIDv7 for index locality
    root         TEXT NOT NULL CHECK (length(root) > 0), -- the canonical workspace directory

    origin            TEXT NOT NULL CHECK (origin IN ('root', 'child', 'fork')),
    parent_id         BLOB    CHECK (parent_id IS NULL OR length(parent_id) = 16), -- proto.SessionId
    parent_message_id INTEGER CHECK (parent_message_id IS NULL OR parent_message_id BETWEEN 1 AND 9007199254740991), -- proto.MessageId
    parent_part_id    INTEGER CHECK (parent_part_id IS NULL OR parent_part_id BETWEEN 0 AND 9007199254740991), -- proto.PartId
    source_id         BLOB    CHECK (source_id IS NULL OR length(source_id) = 16), -- proto.SessionId

    profile    TEXT NOT NULL CHECK (length(profile)   <= 64),
    model      TEXT NOT NULL CHECK (length(CAST(model AS BLOB)) <= 288),
    reasoning  TEXT NOT NULL CHECK (length(reasoning) <= 32),
    config_rev INTEGER NOT NULL CHECK (config_rev BETWEEN 0 AND 9007199254740991), -- proto.ConfigRev
    max_rounds INTEGER CHECK (max_rounds IS NULL OR max_rounds BETWEEN 0 AND 9007199254740991), -- u64
    title      TEXT NOT NULL CHECK (length(title) <= 256),
    agent      TEXT CHECK (agent IS NULL OR length(agent) <= 64),

    created_by_name    TEXT CHECK (created_by_name    IS NULL OR length(created_by_name)    <= 64),
    created_by_version TEXT CHECK (created_by_version IS NULL OR length(created_by_version) <= 32),

    message_count INTEGER NOT NULL DEFAULT 0 CHECK (message_count BETWEEN 0 AND 9007199254740991), -- u64

    -- Sum lifetime token usage for each committed assistant turn. A truncation leaves the total unchanged.
    -- usage_input_total includes the cache subsets.
    usage_input_total       INTEGER NOT NULL DEFAULT 0 CHECK (usage_input_total       BETWEEN 0 AND 9007199254740991), -- u64
    usage_output_total      INTEGER NOT NULL DEFAULT 0 CHECK (usage_output_total      BETWEEN 0 AND 9007199254740991), -- u64
    usage_reasoning_total   INTEGER NOT NULL DEFAULT 0 CHECK (usage_reasoning_total   BETWEEN 0 AND 9007199254740991), -- u64
    usage_cache_read_total  INTEGER NOT NULL DEFAULT 0 CHECK (usage_cache_read_total  BETWEEN 0 AND 9007199254740991), -- u64
    usage_cache_write_total INTEGER NOT NULL DEFAULT 0 CHECK (usage_cache_write_total BETWEEN 0 AND 9007199254740991), -- u64

    created_at_ms INTEGER NOT NULL CHECK (created_at_ms BETWEEN 0 AND 9007199254740991), -- u64
    updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms BETWEEN 0 AND 9007199254740991), -- u64

    -- These id marks only increase. Recovery reads them instead of MAX(seq), so a rewind cannot reclaim ids.
    seq_high        INTEGER NOT NULL DEFAULT 0 CHECK (seq_high        BETWEEN 0 AND 9007199254740991),
    message_id_high INTEGER NOT NULL DEFAULT 0 CHECK (message_id_high BETWEEN 0 AND 9007199254740991),
    run_id_high     INTEGER NOT NULL DEFAULT 0 CHECK (run_id_high     BETWEEN 0 AND 9007199254740991),
    input_id_high   INTEGER NOT NULL DEFAULT 0 CHECK (input_id_high   BETWEEN 0 AND 9007199254740991),
    config_rev_high INTEGER NOT NULL DEFAULT 0 CHECK (config_rev_high BETWEEN 0 AND 9007199254740991),

    -- The read model covers the log through this seq. A projection rebuild raises this value.
    projection_seq INTEGER NOT NULL DEFAULT 0 CHECK (projection_seq BETWEEN 0 AND 9007199254740991),

    -- The recovery marker records an owed terminal event, not activity. A new start closes these fields
    -- at the next restart. The terminal needs all three fields; null means no obligation.
    open_run_id            INTEGER CHECK (open_run_id IS NULL OR open_run_id BETWEEN 1 AND 9007199254740991), -- proto.RunId
    open_run_kind          TEXT    CHECK (open_run_kind IS NULL OR open_run_kind IN ('turn', 'compaction')),
    open_run_started_at_ms INTEGER CHECK (open_run_started_at_ms IS NULL OR open_run_started_at_ms BETWEEN 0 AND 9007199254740991), -- u64

    -- A child has all three parent marks; a non-child has none.
    CHECK (
        (origin =  'child' AND parent_id IS NOT NULL AND parent_message_id IS NOT NULL AND parent_part_id IS NOT NULL) OR
        (origin <> 'child' AND parent_id IS NULL     AND parent_message_id IS NULL     AND parent_part_id IS NULL)
    ),
    CHECK ((origin = 'fork') = (source_id IS NOT NULL)),
    CHECK ((created_by_name IS NULL) = (created_by_version IS NULL)),
    CHECK (updated_at_ms >= created_at_ms),

    -- Open-run columns move as a unit. Set all three while the database owes a terminal; clear all three
    -- after it writes one.
    CHECK ((open_run_id IS NULL) = (open_run_kind IS NULL)),
    CHECK ((open_run_id IS NULL) = (open_run_started_at_ms IS NULL)),
    -- An open run reuses a minted id, so it never exceeds the run high-water mark.
    CHECK (open_run_id IS NULL OR open_run_id <= run_id_high)
) STRICT;

-- Every ORDER BY term uses DESC, and the id tiebreak follows it. An ASC id at the end costs a temp
-- B-tree on every session.list page.
CREATE INDEX sessions_by_recent    ON sessions(updated_at_ms DESC, id DESC);
CREATE INDEX sessions_by_parent    ON sessions(parent_id, updated_at_ms DESC, id DESC) WHERE parent_id IS NOT NULL;

-- The activity log stores full bodies in a rowid table. Keep payload last for overflow I/O.
-- event_id is a stable global id for export or sync; (session_id, seq) is the local stream order.
CREATE TABLE events (
    session_id BLOB NOT NULL CHECK (length(session_id) = 16) -- proto.SessionId
        REFERENCES sessions(id) ON DELETE CASCADE,
    seq          INTEGER NOT NULL CHECK (seq BETWEEN 1 AND 9007199254740991), -- proto.Seq
    event_id     BLOB NOT NULL UNIQUE CHECK (length(event_id) = 16), -- UUIDv7, stable across sync
    committed_at_ms INTEGER NOT NULL CHECK (committed_at_ms BETWEEN 0 AND 9007199254740991), -- u64
    name    TEXT NOT NULL CHECK (length(name)    > 0),
    payload TEXT NOT NULL CHECK (length(payload) > 0)
) STRICT;

-- Name this index so the tail query keeps a stable plan name.
CREATE UNIQUE INDEX events_by_session_seq ON events(session_id, seq);

-- Replay rebuilds this projection from events.payload joined by session_id and seq. The composite FK
-- keeps the pointer valid.
CREATE TABLE messages (
    -- Use a stable alias rowid so FTS5 external-content can index it and VACUUM can keep it fixed.
    search_id  INTEGER PRIMARY KEY,
    session_id BLOB NOT NULL CHECK (length(session_id) = 16) -- proto.SessionId
        REFERENCES sessions(id) ON DELETE CASCADE,
    message_id INTEGER NOT NULL CHECK (message_id BETWEEN 1 AND 9007199254740991), -- proto.MessageId
    seq        INTEGER NOT NULL CHECK (seq        BETWEEN 1 AND 9007199254740991), -- proto.Seq

    role   TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'compaction')),
    run_id     INTEGER CHECK (run_id     IS NULL OR run_id     BETWEEN 1 AND 9007199254740991), -- proto.RunId
    config_rev INTEGER CHECK (config_rev IS NULL OR config_rev BETWEEN 0 AND 9007199254740991), -- proto.ConfigRev

    -- Store the model that answers the turn. Leave it null until the engine records it.
    model    TEXT CHECK (model    IS NULL OR length(CAST(model AS BLOB)) <= 288),
    protocol TEXT CHECK (protocol IS NULL OR length(protocol) <= 32),

    finish TEXT CHECK (finish IS NULL OR
        finish IN ('stop', 'length', 'content_filter', 'refusal', 'tool_calls', 'canceled', 'error', 'unknown')),
    tokens_input       INTEGER CHECK (tokens_input       IS NULL OR tokens_input       BETWEEN 0 AND 9007199254740991), -- u64
    tokens_output      INTEGER CHECK (tokens_output      IS NULL OR tokens_output      BETWEEN 0 AND 9007199254740991), -- u64
    tokens_reasoning   INTEGER CHECK (tokens_reasoning   IS NULL OR tokens_reasoning   BETWEEN 0 AND 9007199254740991), -- u64
    tokens_cache_read  INTEGER CHECK (tokens_cache_read  IS NULL OR tokens_cache_read  BETWEEN 0 AND 9007199254740991), -- u64
    tokens_cache_write INTEGER CHECK (tokens_cache_write IS NULL OR tokens_cache_write BETWEEN 0 AND 9007199254740991), -- u64
    cost               REAL    CHECK (cost               IS NULL OR cost               >= 0),

    created_at_ms INTEGER NOT NULL CHECK (created_at_ms BETWEEN 0 AND 9007199254740991), -- u64

    -- Use a rowid table so FTS5 external-content can index the transcript by rowid later.
    UNIQUE (session_id, message_id),
    FOREIGN KEY (session_id, seq) REFERENCES events(session_id, seq) ON DELETE CASCADE
) STRICT;

-- Index the FK child columns so a session or event cascade can seek instead of a message scan.
CREATE INDEX messages_by_event ON messages(session_id, seq);

-- Index only rows with a recorded model. This supports the query for turns that used a model and adds
-- no cost before the engine records provenance.
CREATE INDEX messages_by_model ON messages(model, created_at_ms) WHERE model IS NOT NULL;

-- Index only the turns that answer the context-usage lookup. The lookup then seeks the newest turn.
CREATE INDEX messages_context_usage ON messages(session_id, message_id)
    WHERE role = 'assistant' AND tokens_input IS NOT NULL;

-- Join each session to the usage of its newest committed assistant turn: the live context gauge.
-- A truncation removes the newest messages, so re-read this instead of a store on the session row.
CREATE VIEW session_context AS
SELECT s.*,
       ctx.tokens_input       AS ctx_tokens_input,
       ctx.tokens_output      AS ctx_tokens_output,
       ctx.tokens_reasoning   AS ctx_tokens_reasoning,
       ctx.tokens_cache_read  AS ctx_tokens_cache_read,
       ctx.tokens_cache_write AS ctx_tokens_cache_write
FROM sessions s
LEFT JOIN messages ctx
       ON ctx.session_id = s.id
      AND ctx.message_id = (
          SELECT message_id FROM messages
           WHERE session_id = s.id AND role = 'assistant' AND tokens_input IS NOT NULL
           ORDER BY message_id DESC LIMIT 1);

-- Replay rebuilds this projection. Store each revision so session.config reads it directly instead of
-- a log scan from seq 1.
CREATE TABLE session_configs (
    session_id BLOB NOT NULL CHECK (length(session_id) = 16) -- proto.SessionId
        REFERENCES sessions(id) ON DELETE CASCADE,
    config_rev INTEGER NOT NULL CHECK (config_rev BETWEEN 0 AND 9007199254740991), -- proto.ConfigRev
    model      TEXT NOT NULL CHECK (length(CAST(model AS BLOB)) <= 288),
    reasoning  TEXT NOT NULL CHECK (length(reasoning) <= 32),
    max_rounds INTEGER CHECK (max_rounds IS NULL OR max_rounds BETWEEN 0 AND 9007199254740991), -- u64

    PRIMARY KEY (session_id, config_rev)
) STRICT, WITHOUT ROWID;

-- Store one prompt per session in a separate table. Create sets it once because the prompt has no fixed bound.
-- An absent row means null.
CREATE TABLE session_prompts (
    session_id BLOB PRIMARY KEY CHECK (length(session_id) = 16) -- proto.SessionId
        REFERENCES sessions(id) ON DELETE CASCADE,
    prompt TEXT NOT NULL,
    base_prompt TEXT NOT NULL,
    instructions TEXT NOT NULL,
    skills TEXT NOT NULL,
    child_policy TEXT,
    environment TEXT NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE session_instructions (
    session_id BLOB NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    scope TEXT NOT NULL CHECK (scope IN ('global', 'workspace')),
    path TEXT NOT NULL,
    canonical_path TEXT NOT NULL,
    content_hash BLOB NOT NULL CHECK (length(content_hash) = 32),
    text TEXT NOT NULL,
    PRIMARY KEY (session_id, scope),
    UNIQUE (session_id, canonical_path)
) STRICT, WITHOUT ROWID;

-- The skill catalog snapshot. It holds no body, because skill.load reads the file at invocation.
CREATE TABLE session_skills (
    session_id BLOB NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 64),
    description TEXT NOT NULL CHECK (length(description) BETWEEN 1 AND 1024),
    scope TEXT NOT NULL CHECK (scope IN ('global', 'workspace')),
    path TEXT NOT NULL,
    canonical_path TEXT NOT NULL,
    PRIMARY KEY (session_id, name),
    UNIQUE (session_id, canonical_path)
) STRICT, WITHOUT ROWID;
