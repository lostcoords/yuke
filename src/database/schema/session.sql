-- The workspace registry and the session registry. Numeric upper bounds are 2^53-1,
-- the largest integer the wire JSON round-trips exactly.

-- The daemon mints an opaque id, not a path hash, so container and cloud kinds fit later.
-- A persistent local root sets stable_key to the canonical path; an ephemeral one leaves it null.
CREATE TABLE workspaces (
    id   BLOB PRIMARY KEY CHECK (typeof(id) = 'blob' AND length(id) = 16), -- wire.WorkspaceId
    kind TEXT NOT NULL CHECK (kind IN ('local')),
    root  TEXT CHECK (root IS NULL OR (typeof(root) = 'text' AND length(root) > 0)),
    title TEXT NOT NULL CHECK (typeof(title) = 'text' AND length(title) <= 256),

    stable_key TEXT CHECK (stable_key IS NULL OR (typeof(stable_key) = 'text' AND length(stable_key) > 0)),

    -- A local workspace has a root; other kinds will not.
    CHECK ((kind = 'local') = (root IS NOT NULL)),
    -- A null stable_key repeats freely; SQLite treats each null as distinct.
    UNIQUE (kind, stable_key)
) WITHOUT ROWID;

-- Primary state, not derived: session.summary_changed never reaches the event log.
-- Flatten Session_Origin; each arm's ids are non-null only for that arm.
CREATE TABLE sessions (
    id           BLOB PRIMARY KEY CHECK (typeof(id) = 'blob' AND length(id) = 16), -- wire.SessionId
    workspace_id BLOB NOT NULL -- wire.WorkspaceId
        CHECK (typeof(workspace_id) = 'blob' AND length(workspace_id) = 16)
        REFERENCES workspaces(id),

    origin            TEXT NOT NULL CHECK (origin IN ('root', 'child', 'fork', 'cron')),
    parent_id         BLOB    CHECK (parent_id IS NULL OR (typeof(parent_id) = 'blob' AND length(parent_id) = 16)), -- wire.SessionId
    parent_message_id INTEGER CHECK (parent_message_id IS NULL OR parent_message_id BETWEEN 1 AND 9007199254740991), -- wire.MessageId
    parent_part_id    INTEGER CHECK (parent_part_id IS NULL OR parent_part_id BETWEEN 0 AND 9007199254740991), -- wire.PartId
    source_id         BLOB    CHECK (source_id IS NULL OR (typeof(source_id) = 'blob' AND length(source_id) = 16)), -- wire.SessionId
    job_id            BLOB    CHECK (job_id IS NULL OR (typeof(job_id) = 'blob' AND length(job_id) = 16)), -- wire.JobId

    profile    TEXT NOT NULL CHECK (typeof(profile)   = 'text' AND length(profile)   <= 64),
    model      TEXT NOT NULL CHECK (typeof(model)     = 'text' AND length(model)     <= 128),
    reasoning  TEXT NOT NULL CHECK (typeof(reasoning) = 'text' AND length(reasoning) <= 32),
    config_rev INTEGER NOT NULL CHECK (config_rev BETWEEN 0 AND 9007199254740991), -- wire.ConfigRev
    permission TEXT NOT NULL CHECK (permission IN ('strict', 'normal', 'yolo')),
    max_rounds INTEGER CHECK (max_rounds IS NULL OR max_rounds BETWEEN 0 AND 9007199254740991), -- u64
    title      TEXT NOT NULL CHECK (typeof(title) = 'text' AND length(title) <= 256),
    agent      TEXT CHECK (agent IS NULL OR (typeof(agent) = 'text' AND length(agent) <= 64)),

    created_by_name    TEXT CHECK (created_by_name    IS NULL OR (typeof(created_by_name)    = 'text' AND length(created_by_name)    <= 64)),
    created_by_version TEXT CHECK (created_by_version IS NULL OR (typeof(created_by_version) = 'text' AND length(created_by_version) <= 32)),

    message_count INTEGER NOT NULL DEFAULT 0 CHECK (message_count BETWEEN 0 AND 9007199254740991), -- u64

    -- Lifetime token usage, summed over every committed assistant turn. Monotonic; a
    -- truncation never subtracts. `usage_input_total` folds in the cache subsets.
    usage_input_total       INTEGER NOT NULL DEFAULT 0 CHECK (usage_input_total       BETWEEN 0 AND 9007199254740991), -- u64
    usage_output_total      INTEGER NOT NULL DEFAULT 0 CHECK (usage_output_total      BETWEEN 0 AND 9007199254740991), -- u64
    usage_reasoning_total   INTEGER NOT NULL DEFAULT 0 CHECK (usage_reasoning_total   BETWEEN 0 AND 9007199254740991), -- u64
    usage_cache_read_total  INTEGER NOT NULL DEFAULT 0 CHECK (usage_cache_read_total  BETWEEN 0 AND 9007199254740991), -- u64
    usage_cache_write_total INTEGER NOT NULL DEFAULT 0 CHECK (usage_cache_write_total BETWEEN 0 AND 9007199254740991), -- u64

    created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0), -- u64
    updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms >= 0), -- u64

    -- Id-minting marks. Monotonic; only raised. Recovery reads these, never MAX(seq):
    -- a truncating rewind would reclaim ids.
    seq_high        INTEGER NOT NULL DEFAULT 0 CHECK (seq_high        BETWEEN 0 AND 9007199254740991),
    message_id_high INTEGER NOT NULL DEFAULT 0 CHECK (message_id_high BETWEEN 0 AND 9007199254740991),
    run_id_high     INTEGER NOT NULL DEFAULT 0 CHECK (run_id_high     BETWEEN 0 AND 9007199254740991),
    input_id_high   INTEGER NOT NULL DEFAULT 0 CHECK (input_id_high   BETWEEN 0 AND 9007199254740991),
    config_rev_high INTEGER NOT NULL DEFAULT 0 CHECK (config_rev_high BETWEEN 0 AND 9007199254740991),

    -- Recovery marker, not activity: a start closes these at the next restart. These are
    -- the three fields a terminal needs; all null when nothing is owed.
    open_run_id            INTEGER DEFAULT NULL CHECK (open_run_id            IS NULL OR open_run_id            BETWEEN 1 AND 9007199254740991), -- wire.RunId
    open_run_kind          TEXT    DEFAULT NULL CHECK (open_run_kind          IS NULL OR open_run_kind          IN ('turn', 'compaction')),
    open_run_started_at_ms INTEGER DEFAULT NULL CHECK (open_run_started_at_ms IS NULL OR open_run_started_at_ms >= 0), -- u64

    -- Table constraints follow every column; SQLite rejects them interleaved.
    -- A child has all three parent marks; a non-child has none.
    CHECK (
        (origin =  'child' AND parent_id IS NOT NULL AND parent_message_id IS NOT NULL AND parent_part_id IS NOT NULL) OR
        (origin <> 'child' AND parent_id IS NULL     AND parent_message_id IS NULL     AND parent_part_id IS NULL)
    ),
    CHECK ((origin = 'fork')  = (source_id IS NOT NULL)),
    CHECK ((origin = 'cron')  = (job_id IS NOT NULL)),
    CHECK ((created_by_name IS NULL) = (created_by_version IS NULL)),
    CHECK (updated_at_ms >= created_at_ms),

    -- Open-run columns move as a unit: all set while a terminal is owed, all null once
    -- one is written.
    CHECK ((open_run_id IS NULL) = (open_run_kind IS NULL)),
    CHECK ((open_run_id IS NULL) = (open_run_started_at_ms IS NULL))
) WITHOUT ROWID;

-- Every ORDER BY term is DESC, including the id tiebreak; a trailing ASC id costs a temp
-- B-tree on every session.list page.
CREATE INDEX sessions_by_recent    ON sessions(updated_at_ms DESC, id DESC);
CREATE INDEX sessions_by_workspace ON sessions(workspace_id, updated_at_ms DESC, id DESC);
CREATE INDEX sessions_by_parent    ON sessions(parent_id, updated_at_ms DESC, id DESC) WHERE parent_id IS NOT NULL;
CREATE INDEX sessions_by_job       ON sessions(job_id, updated_at_ms DESC, id DESC)    WHERE job_id IS NOT NULL;
