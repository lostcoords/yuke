-- The session registry, the event log of record, and the transcript projection.
-- Shipped migration text is immutable: add a step, never edit one. Numeric upper
-- bounds are 2^53-1, the largest integer the wire's JSON round-trips exactly.

-- Primary state, not derived: session.summary_changed is Ungated and never reaches the
-- log, so nothing here rebuilds by replay. Carries the id-minting marks too, one row per
-- session, and `origin` flattened from the Session_Origin union with each arm's ids
-- non-null exactly for that arm.
CREATE TABLE sessions (
    id           BLOB PRIMARY KEY CHECK (typeof(id) = 'blob' AND length(id) = 16),
    workspace_id BLOB NOT NULL    CHECK (typeof(workspace_id) = 'blob' AND length(workspace_id) = 16),

    origin            TEXT NOT NULL CHECK (origin IN ('root', 'child', 'fork', 'cron')),
    parent_id         BLOB    CHECK (parent_id IS NULL OR (typeof(parent_id) = 'blob' AND length(parent_id) = 16)),
    parent_message_id INTEGER CHECK (parent_message_id IS NULL OR parent_message_id BETWEEN 1 AND 9007199254740991),
    parent_part_id    INTEGER CHECK (parent_part_id IS NULL OR parent_part_id BETWEEN 0 AND 9007199254740991),
    source_id         BLOB    CHECK (source_id IS NULL OR (typeof(source_id) = 'blob' AND length(source_id) = 16)),
    job_id            BLOB    CHECK (job_id IS NULL OR (typeof(job_id) = 'blob' AND length(job_id) = 16)),

    profile    TEXT NOT NULL CHECK (typeof(profile)   = 'text' AND length(profile)   <= 64),
    model      TEXT NOT NULL CHECK (typeof(model)     = 'text' AND length(model)     <= 128),
    reasoning  TEXT NOT NULL CHECK (typeof(reasoning) = 'text' AND length(reasoning) <= 32),
    config_rev INTEGER NOT NULL CHECK (config_rev BETWEEN 0 AND 9007199254740991),
    permission TEXT NOT NULL CHECK (permission IN ('strict', 'normal', 'yolo')),
    max_rounds INTEGER CHECK (max_rounds IS NULL OR max_rounds BETWEEN 0 AND 9007199254740991),
    title      TEXT NOT NULL CHECK (typeof(title) = 'text' AND length(title) <= 256),
    agent      TEXT CHECK (agent IS NULL OR (typeof(agent) = 'text' AND length(agent) <= 64)),

    created_by_name    TEXT CHECK (created_by_name    IS NULL OR (typeof(created_by_name)    = 'text' AND length(created_by_name)    <= 64)),
    created_by_version TEXT CHECK (created_by_version IS NULL OR (typeof(created_by_version) = 'text' AND length(created_by_version) <= 32)),

    message_count INTEGER NOT NULL DEFAULT 0 CHECK (message_count BETWEEN 0 AND 9007199254740991),
    created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),
    updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms >= 0),

    -- Id-minting marks. Monotonic; only ever raised. Recovery reads these, never
    -- MAX(seq) over events: a truncating rewind would reclaim ids.
    seq_high        INTEGER NOT NULL DEFAULT 0 CHECK (seq_high        BETWEEN 0 AND 9007199254740991),
    message_id_high INTEGER NOT NULL DEFAULT 0 CHECK (message_id_high BETWEEN 0 AND 9007199254740991),
    run_id_high     INTEGER NOT NULL DEFAULT 0 CHECK (run_id_high     BETWEEN 0 AND 9007199254740991),
    input_id_high   INTEGER NOT NULL DEFAULT 0 CHECK (input_id_high   BETWEEN 0 AND 9007199254740991),
    config_rev_high INTEGER NOT NULL DEFAULT 0 CHECK (config_rev_high BETWEEN 0 AND 9007199254740991),

    -- Table constraints follow every column definition; SQLite rejects them interleaved.
    CHECK ((origin = 'child') = (parent_id IS NOT NULL AND parent_message_id IS NOT NULL AND parent_part_id IS NOT NULL)),
    CHECK ((origin = 'fork')  = (source_id IS NOT NULL)),
    CHECK ((origin = 'cron')  = (job_id IS NOT NULL)),
    CHECK ((created_by_name IS NULL) = (created_by_version IS NULL)),
    CHECK (updated_at_ms >= created_at_ms)
) WITHOUT ROWID;

-- Every ORDER BY term is DESC including the trailing id tiebreak; a trailing ASC
-- id costs a temp B-tree on every session.list page and keeps the keyset tuple
-- out of the index seek.
CREATE INDEX sessions_by_recent    ON sessions(updated_at_ms DESC, id DESC);
CREATE INDEX sessions_by_workspace ON sessions(workspace_id, updated_at_ms DESC, id DESC);
CREATE INDEX sessions_by_parent    ON sessions(parent_id, updated_at_ms DESC, id DESC) WHERE parent_id IS NOT NULL;
CREATE INDEX sessions_by_job       ON sessions(job_id, updated_at_ms DESC, id DESC)    WHERE job_id IS NOT NULL;

-- The log of record. A rowid table, not WITHOUT ROWID: payloads are whole committed
-- messages, and WITHOUT ROWID stores content in interior B-tree nodes too, collapsing
-- fanout on the tail read. `payload` stays last so earlier columns never pay overflow I/O.
CREATE TABLE events (
    session_id BLOB NOT NULL
        CHECK (typeof(session_id) = 'blob' AND length(session_id) = 16)
        REFERENCES sessions(id) ON DELETE CASCADE,
    seq INTEGER NOT NULL
        CHECK (typeof(seq) = 'integer' AND seq BETWEEN 1 AND 9007199254740991),
    name TEXT NOT NULL
        CHECK (typeof(name) = 'text' AND length(name) > 0),
    payload TEXT NOT NULL
        CHECK (typeof(payload) = 'text' AND length(payload) > 0)
);

-- Named rather than left to a UNIQUE constraint's sqlite_autoindex_*, so the
-- tail read's index has a stable name in query plans.
CREATE UNIQUE INDEX events_by_session_seq ON events(session_id, seq);

-- Projection of `events`, rebuildable by replay. Scalars and a pointer only: the
-- message body stays in events.payload and is joined back by (session_id, seq).
-- The primary key is session.history's page: keyset, newest message id first.
CREATE TABLE messages (
    session_id BLOB NOT NULL
        CHECK (typeof(session_id) = 'blob' AND length(session_id) = 16)
        REFERENCES sessions(id) ON DELETE CASCADE,
    message_id INTEGER NOT NULL CHECK (message_id BETWEEN 1 AND 9007199254740991),
    seq        INTEGER NOT NULL CHECK (seq        BETWEEN 1 AND 9007199254740991),

    role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'compaction')),
    run_id     INTEGER CHECK (run_id     IS NULL OR run_id     BETWEEN 1 AND 9007199254740991),
    config_rev INTEGER CHECK (config_rev IS NULL OR config_rev BETWEEN 0 AND 9007199254740991),

    -- What answered, from the turn's provenance — not the config_rev it was
    -- requested under. Null until the engine records provenance.
    model    TEXT CHECK (model    IS NULL OR (typeof(model)    = 'text' AND length(model)    <= 128)),
    protocol TEXT CHECK (protocol IS NULL OR (typeof(protocol) = 'text' AND length(protocol) <= 32)),

    finish TEXT CHECK (finish IS NULL OR
        finish IN ('stop', 'length', 'content_filter', 'tool_calls', 'canceled', 'error', 'unknown')),
    tokens_input       INTEGER CHECK (tokens_input       IS NULL OR tokens_input       >= 0),
    tokens_output      INTEGER CHECK (tokens_output      IS NULL OR tokens_output      >= 0),
    tokens_reasoning   INTEGER CHECK (tokens_reasoning   IS NULL OR tokens_reasoning   >= 0),
    tokens_cache_read  INTEGER CHECK (tokens_cache_read  IS NULL OR tokens_cache_read  >= 0),
    tokens_cache_write INTEGER CHECK (tokens_cache_write IS NULL OR tokens_cache_write >= 0),
    cost               REAL    CHECK (cost               IS NULL OR cost               >= 0),

    created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0),

    PRIMARY KEY (session_id, message_id)
) WITHOUT ROWID;

-- Partial: no row carries a model until the engine records provenance, so this
-- costs nothing until it is the index that answers "which turns used X".
CREATE INDEX messages_by_model ON messages(model, created_at_ms) WHERE model IS NOT NULL;
