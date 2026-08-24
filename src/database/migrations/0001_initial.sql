-- The design has mutable registry tables plus an append-only activity log; projections rebuild from it.
-- STRICT types enforce storage; checks enforce domain rules; numeric bounds are 2^53-1 (wire JSON safe).

-- The models.dev catalog. A thin key/value store until a typed catalog schema lands.
CREATE TABLE catalog_meta (
    k TEXT PRIMARY KEY,
    v TEXT NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE catalog_providers (
    id   TEXT PRIMARY KEY,
    data TEXT NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE catalog_models (
    id          TEXT PRIMARY KEY,
    provider_id TEXT NOT NULL,
    data        TEXT NOT NULL
) STRICT, WITHOUT ROWID;

CREATE INDEX catalog_models_by_provider ON catalog_models (provider_id);

-- The daemon mints an opaque id, not a path hash, so container and cloud kinds fit later.
-- A persistent local root sets stable_key to the canonical path; an ephemeral one leaves it null.
CREATE TABLE workspaces (
    id   BLOB PRIMARY KEY CHECK (length(id) = 16), -- wire.WorkspaceId
    kind TEXT NOT NULL CHECK (kind IN ('local')),
    root  TEXT CHECK (root IS NULL OR length(root) > 0),
    title TEXT NOT NULL CHECK (length(title) <= 256),

    stable_key TEXT CHECK (stable_key IS NULL OR length(stable_key) > 0),

    -- A local workspace must have a root. Other kinds must not have one.
    CHECK ((kind = 'local') = (root IS NOT NULL)),
    -- A null stable_key repeats freely; SQLite treats each null as distinct.
    UNIQUE (kind, stable_key)
) STRICT, WITHOUT ROWID;

-- The session registry holds primary state; it is not derived from the log. A rowid table suits this
-- wide, frequently updated row. Flatten Session_Origin; each arm's ids are non-null only for that arm.
CREATE TABLE sessions (
    id           BLOB NOT NULL UNIQUE CHECK (length(id) = 16), -- wire.SessionId; UUIDv7 for index locality
    workspace_id BLOB NOT NULL CHECK (length(workspace_id) = 16) REFERENCES workspaces(id), -- wire.WorkspaceId

    origin            TEXT NOT NULL CHECK (origin IN ('root', 'child', 'fork')),
    parent_id         BLOB    CHECK (parent_id IS NULL OR length(parent_id) = 16), -- wire.SessionId
    parent_message_id INTEGER CHECK (parent_message_id IS NULL OR parent_message_id BETWEEN 1 AND 9007199254740991), -- wire.MessageId
    parent_part_id    INTEGER CHECK (parent_part_id IS NULL OR parent_part_id BETWEEN 0 AND 9007199254740991), -- wire.PartId
    source_id         BLOB    CHECK (source_id IS NULL OR length(source_id) = 16), -- wire.SessionId

    profile    TEXT NOT NULL CHECK (length(profile)   <= 64),
    model      TEXT NOT NULL CHECK (length(model)     <= 128),
    reasoning  TEXT NOT NULL CHECK (length(reasoning) <= 32),
    config_rev INTEGER NOT NULL CHECK (config_rev BETWEEN 0 AND 9007199254740991), -- wire.ConfigRev
    permission TEXT NOT NULL CHECK (permission IN ('strict', 'normal', 'yolo')),
    max_rounds INTEGER CHECK (max_rounds IS NULL OR max_rounds BETWEEN 0 AND 9007199254740991), -- u64
    title      TEXT NOT NULL CHECK (length(title) <= 256),
    agent      TEXT CHECK (agent IS NULL OR length(agent) <= 64),

    created_by_name    TEXT CHECK (created_by_name    IS NULL OR length(created_by_name)    <= 64),
    created_by_version TEXT CHECK (created_by_version IS NULL OR length(created_by_version) <= 32),

    message_count INTEGER NOT NULL DEFAULT 0 CHECK (message_count BETWEEN 0 AND 9007199254740991), -- u64

    -- Sum lifetime token usage over each committed assistant turn; a truncation never
    -- subtracts. usage_input_total includes the cache subsets.
    usage_input_total       INTEGER NOT NULL DEFAULT 0 CHECK (usage_input_total       BETWEEN 0 AND 9007199254740991), -- u64
    usage_output_total      INTEGER NOT NULL DEFAULT 0 CHECK (usage_output_total      BETWEEN 0 AND 9007199254740991), -- u64
    usage_reasoning_total   INTEGER NOT NULL DEFAULT 0 CHECK (usage_reasoning_total   BETWEEN 0 AND 9007199254740991), -- u64
    usage_cache_read_total  INTEGER NOT NULL DEFAULT 0 CHECK (usage_cache_read_total  BETWEEN 0 AND 9007199254740991), -- u64
    usage_cache_write_total INTEGER NOT NULL DEFAULT 0 CHECK (usage_cache_write_total BETWEEN 0 AND 9007199254740991), -- u64

    created_at_ms INTEGER NOT NULL CHECK (created_at_ms BETWEEN 0 AND 9007199254740991), -- u64
    updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms BETWEEN 0 AND 9007199254740991), -- u64

    -- These id marks only increase. Recovery reads them, never MAX(seq), so a truncating
    -- rewind cannot reclaim ids.
    seq_high        INTEGER NOT NULL DEFAULT 0 CHECK (seq_high        BETWEEN 0 AND 9007199254740991),
    message_id_high INTEGER NOT NULL DEFAULT 0 CHECK (message_id_high BETWEEN 0 AND 9007199254740991),
    run_id_high     INTEGER NOT NULL DEFAULT 0 CHECK (run_id_high     BETWEEN 0 AND 9007199254740991),
    input_id_high   INTEGER NOT NULL DEFAULT 0 CHECK (input_id_high   BETWEEN 0 AND 9007199254740991),
    config_rev_high INTEGER NOT NULL DEFAULT 0 CHECK (config_rev_high BETWEEN 0 AND 9007199254740991),

    -- The read model reflects the log through this seq. The projections slice raises it on rebuild.
    projection_seq INTEGER NOT NULL DEFAULT 0 CHECK (projection_seq BETWEEN 0 AND 9007199254740991),

    -- Recovery marker, not activity: a start closes these at the next restart. These are
    -- the three fields a terminal needs; all null when nothing is owed.
    open_run_id            INTEGER CHECK (open_run_id IS NULL OR open_run_id BETWEEN 1 AND 9007199254740991), -- wire.RunId
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

    -- Open-run columns move as a unit: all set while a terminal is owed, all null once one is written.
    CHECK ((open_run_id IS NULL) = (open_run_kind IS NULL)),
    CHECK ((open_run_id IS NULL) = (open_run_started_at_ms IS NULL)),
    -- An open run reuses a minted id, so it never exceeds the run high-water mark.
    CHECK (open_run_id IS NULL OR open_run_id <= run_id_high)
) STRICT;

-- Every ORDER BY term is DESC, including the id tiebreak; a trailing ASC id costs a temp
-- B-tree on every session.list page.
CREATE INDEX sessions_by_recent    ON sessions(updated_at_ms DESC, id DESC);
CREATE INDEX sessions_by_workspace ON sessions(workspace_id, updated_at_ms DESC, id DESC);
CREATE INDEX sessions_by_parent    ON sessions(parent_id, updated_at_ms DESC, id DESC) WHERE parent_id IS NOT NULL;

-- The append-only activity log. A rowid table holds full bodies; keep payload last for overflow I/O.
-- event_id is a stable global id for export or sync; (session_id, seq) is the local stream order.
CREATE TABLE events (
    session_id BLOB NOT NULL CHECK (length(session_id) = 16) -- wire.SessionId
        REFERENCES sessions(id) ON DELETE CASCADE,
    seq          INTEGER NOT NULL CHECK (seq BETWEEN 1 AND 9007199254740991), -- wire.Seq
    event_id     BLOB NOT NULL UNIQUE CHECK (length(event_id) = 16), -- UUIDv7, stable across sync
    committed_at_ms INTEGER NOT NULL CHECK (committed_at_ms BETWEEN 0 AND 9007199254740991), -- u64
    name    TEXT NOT NULL CHECK (length(name)    > 0),
    payload TEXT NOT NULL CHECK (length(payload) > 0)
) STRICT;

-- Name this index so the tail query keeps a stable plan name.
CREATE UNIQUE INDEX events_by_session_seq ON events(session_id, seq);

-- Replay rebuilds this projection. Keep the body in events.payload and join by
-- (session_id, seq). The composite FK stops the pointer from dangling.
CREATE TABLE messages (
    -- A stable alias rowid. FTS5 external-content will index by it and VACUUM keeps it fixed.
    search_id  INTEGER PRIMARY KEY,
    session_id BLOB NOT NULL CHECK (length(session_id) = 16) -- wire.SessionId
        REFERENCES sessions(id) ON DELETE CASCADE,
    message_id INTEGER NOT NULL CHECK (message_id BETWEEN 1 AND 9007199254740991), -- wire.MessageId
    seq        INTEGER NOT NULL CHECK (seq        BETWEEN 1 AND 9007199254740991), -- wire.Seq

    role   TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'compaction')),
    run_id     INTEGER CHECK (run_id     IS NULL OR run_id     BETWEEN 1 AND 9007199254740991), -- wire.RunId
    config_rev INTEGER CHECK (config_rev IS NULL OR config_rev BETWEEN 0 AND 9007199254740991), -- wire.ConfigRev

    -- Store the answering model from turn provenance. Leave it null until the engine records it.
    model    TEXT CHECK (model    IS NULL OR length(model)    <= 128),
    protocol TEXT CHECK (protocol IS NULL OR length(protocol) <= 32),

    finish TEXT CHECK (finish IS NULL OR
        finish IN ('stop', 'length', 'content_filter', 'tool_calls', 'canceled', 'error', 'unknown')),
    tokens_input       INTEGER CHECK (tokens_input       IS NULL OR tokens_input       BETWEEN 0 AND 9007199254740991), -- u64
    tokens_output      INTEGER CHECK (tokens_output      IS NULL OR tokens_output      BETWEEN 0 AND 9007199254740991), -- u64
    tokens_reasoning   INTEGER CHECK (tokens_reasoning   IS NULL OR tokens_reasoning   BETWEEN 0 AND 9007199254740991), -- u64
    tokens_cache_read  INTEGER CHECK (tokens_cache_read  IS NULL OR tokens_cache_read  BETWEEN 0 AND 9007199254740991), -- u64
    tokens_cache_write INTEGER CHECK (tokens_cache_write IS NULL OR tokens_cache_write BETWEEN 0 AND 9007199254740991), -- u64
    cost               REAL    CHECK (cost               IS NULL OR cost               >= 0),

    created_at_ms INTEGER NOT NULL CHECK (created_at_ms BETWEEN 0 AND 9007199254740991), -- u64

    -- A rowid table so FTS5 external-content can index the transcript by rowid later.
    UNIQUE (session_id, message_id),
    FOREIGN KEY (session_id, seq) REFERENCES events(session_id, seq) ON DELETE CASCADE
) STRICT;

-- Index the FK child columns so a session or event cascade seeks instead of scanning messages.
CREATE INDEX messages_by_event ON messages(session_id, seq);

-- Index only rows with a recorded model. This answers "which turns used X" and costs
-- nothing before the engine records provenance.
CREATE INDEX messages_by_model ON messages(model, created_at_ms) WHERE model IS NOT NULL;

-- Replay rebuilds this projection. Store each revision so session.config reads it
-- directly, not by folding the log from seq 1.
CREATE TABLE session_configs (
    session_id BLOB NOT NULL CHECK (length(session_id) = 16) -- wire.SessionId
        REFERENCES sessions(id) ON DELETE CASCADE,
    config_rev INTEGER NOT NULL CHECK (config_rev BETWEEN 0 AND 9007199254740991), -- wire.ConfigRev
    model      TEXT NOT NULL CHECK (length(model)     <= 128),
    reasoning  TEXT NOT NULL CHECK (length(reasoning) <= 32),

    PRIMARY KEY (session_id, config_rev)
) STRICT, WITHOUT ROWID;

-- Store one prompt per session. Create sets it and no method changes it. Keep it outside
-- sessions because the prompt has no fixed bound. A missing row means null.
CREATE TABLE session_prompts (
    session_id BLOB PRIMARY KEY CHECK (length(session_id) = 16) -- wire.SessionId
        REFERENCES sessions(id) ON DELETE CASCADE,
    prompt TEXT NOT NULL
) STRICT, WITHOUT ROWID;
