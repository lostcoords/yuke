-- Provider credentials and catalog sources, the session registry, the event log
-- of record, and the transcript projection.
-- This pre-release baseline is intentionally rebased instead of carrying upgrade
-- history for private disposable databases. Numeric upper bounds are 2^53-1, the
-- largest integer the wire's JSON round-trips exactly.

-- The discriminator and nullability checks keep the two credential arms closed:
-- a row is exactly one API key or one OAuth grant.
CREATE TABLE provider_credentials (
    provider_id TEXT PRIMARY KEY
        CHECK (
            typeof(provider_id) = 'text' AND
            length(provider_id) BETWEEN 1 AND 64 AND
            length(CAST(provider_id AS BLOB)) = length(provider_id) AND
            provider_id NOT GLOB '*[^a-z0-9._-]*'
        ),
    kind TEXT NOT NULL CHECK (typeof(kind) = 'text' AND kind IN ('api_key', 'oauth')),

    api_key       TEXT CHECK (api_key       IS NULL OR (typeof(api_key)       = 'text' AND length(CAST(api_key       AS BLOB)) BETWEEN 1 AND 65536)),
    access_token  TEXT CHECK (access_token  IS NULL OR (typeof(access_token)  = 'text' AND length(CAST(access_token  AS BLOB)) BETWEEN 1 AND 65536)),
    refresh_token TEXT CHECK (refresh_token IS NULL OR (typeof(refresh_token) = 'text' AND length(CAST(refresh_token AS BLOB)) BETWEEN 1 AND 65536)),
    expires_at_ms INTEGER CHECK (expires_at_ms IS NULL OR (typeof(expires_at_ms) = 'integer' AND expires_at_ms BETWEEN 1 AND 9007199254740991)),
    account_id    TEXT CHECK (account_id IS NULL OR (typeof(account_id) = 'text' AND length(CAST(account_id AS BLOB)) BETWEEN 1 AND 4096)),

    CHECK (
        (kind = 'api_key' AND
            api_key IS NOT NULL AND
            access_token IS NULL AND refresh_token IS NULL AND
            expires_at_ms IS NULL AND account_id IS NULL) OR
        (kind = 'oauth' AND
            api_key IS NULL AND
            access_token IS NOT NULL AND refresh_token IS NOT NULL AND
            expires_at_ms IS NOT NULL)
    )
) WITHOUT ROWID;

-- Imported snapshots and startup JavaScript definitions deliberately coexist.
-- Source remains in the key so removing an overlay reveals, rather than destroys,
-- the imported provider beneath it. An imported provider is complete; a JavaScript
-- provider may inherit its endpoint from models.dev.
CREATE TABLE catalog_providers (
    provider_id TEXT NOT NULL,
    source      TEXT NOT NULL CHECK (source IN ('models_dev', 'javascript')),

    models_dev_id TEXT CHECK (models_dev_id IS NULL OR (
        typeof(models_dev_id) = 'text' AND
        length(CAST(models_dev_id AS BLOB)) BETWEEN 1 AND 64 AND
        models_dev_id NOT GLOB '*[^a-z0-9._-]*'
    )),
    name     TEXT CHECK (name     IS NULL OR (typeof(name)     = 'text' AND length(CAST(name     AS BLOB)) BETWEEN 1 AND 128)),
    base_url TEXT CHECK (base_url IS NULL OR (typeof(base_url) = 'text' AND length(CAST(base_url AS BLOB)) BETWEEN 1 AND 4096)),
    protocol TEXT CHECK (protocol IS NULL OR protocol IN ('anthropic-messages', 'openai-completions', 'openai-responses')),
    etag     TEXT CHECK (etag     IS NULL OR (typeof(etag)     = 'text' AND length(CAST(etag     AS BLOB)) BETWEEN 1 AND 4096)),

    PRIMARY KEY (provider_id, source),

    CHECK (
        typeof(provider_id) = 'text' AND
        length(CAST(provider_id AS BLOB)) BETWEEN 1 AND 64 AND
        provider_id NOT GLOB '*[^a-z0-9._-]*'
    ),
    CHECK ((base_url IS NULL) = (protocol IS NULL)),
    CHECK (
        (source = 'models_dev' AND
            models_dev_id IS NOT NULL AND name IS NOT NULL AND
            base_url IS NOT NULL) OR
        (source = 'javascript' AND etag IS NULL AND
            (models_dev_id IS NOT NULL OR base_url IS NOT NULL))
    )
) WITHOUT ROWID;

-- Credential environment names retain declaration/source order. They are public
-- configuration names, never credential values.
CREATE TABLE catalog_provider_env (
    provider_id TEXT NOT NULL,
    source      TEXT NOT NULL,
    ordinal     INTEGER NOT NULL CHECK (typeof(ordinal) = 'integer' AND ordinal BETWEEN 0 AND 31),
    name        TEXT NOT NULL CHECK (
        typeof(name) = 'text' AND
        length(CAST(name AS BLOB)) BETWEEN 1 AND 128
    ),

    PRIMARY KEY (provider_id, source, ordinal),
    UNIQUE (provider_id, source, name),
    FOREIGN KEY (provider_id, source)
        REFERENCES catalog_providers(provider_id, source) ON DELETE CASCADE
) WITHOUT ROWID;

-- A model row is either a complete imported/custom inference record or a partial
-- JavaScript override. `source` and `kind` remain in the key so collisions survive
-- persistence for deliberate overlay validation instead of becoming last-write-wins.
CREATE TABLE catalog_models (
    public_model_id TEXT NOT NULL,
    provider_id     TEXT NOT NULL,
    source          TEXT NOT NULL CHECK (source IN ('models_dev', 'javascript')),
    kind            TEXT NOT NULL CHECK (kind IN ('model', 'override')),

    upstream_id       TEXT,
    name              TEXT,
    context_window    INTEGER, -- u64
    max_output_tokens INTEGER, -- u64
    base_url           TEXT,
    protocol           TEXT,
    supports_temperature INTEGER,
    reasoning_replay     TEXT,
    reasoning_format     TEXT,
    reasoning_budget_min INTEGER, -- i64
    reasoning_budget_max INTEGER, -- u64
    supports_vision INTEGER,
    supports_tools  INTEGER,
    cost_input       REAL,
    cost_output      REAL,
    cost_cache_read  REAL,
    cost_cache_write REAL,

    PRIMARY KEY (public_model_id, source, kind),
    FOREIGN KEY (provider_id, source)
        REFERENCES catalog_providers(provider_id, source) ON DELETE CASCADE,

    CHECK (typeof(public_model_id) = 'text' AND length(CAST(public_model_id AS BLOB)) BETWEEN 1 AND 128),
    CHECK (typeof(provider_id) = 'text' AND length(CAST(provider_id AS BLOB)) BETWEEN 1 AND 64),
    CHECK (upstream_id IS NULL OR (typeof(upstream_id) = 'text' AND length(CAST(upstream_id AS BLOB)) BETWEEN 1 AND 128)),
    CHECK (name IS NULL OR (typeof(name) = 'text' AND length(CAST(name AS BLOB)) BETWEEN 1 AND 128)),
    CHECK (context_window IS NULL OR (typeof(context_window) = 'integer' AND context_window BETWEEN 1 AND 9007199254740991)),
    CHECK (max_output_tokens IS NULL OR (typeof(max_output_tokens) = 'integer' AND max_output_tokens BETWEEN 1 AND 9007199254740991)),
    CHECK (base_url IS NULL OR (typeof(base_url) = 'text' AND length(CAST(base_url AS BLOB)) BETWEEN 1 AND 4096)),
    CHECK (protocol IS NULL OR protocol IN ('anthropic-messages', 'openai-completions', 'openai-responses')),
    CHECK (supports_temperature IS NULL OR (typeof(supports_temperature) = 'integer' AND supports_temperature IN (0, 1))),
    CHECK (reasoning_replay IS NULL OR reasoning_replay IN ('none', 'reasoning-content', 'reasoning-details')),
    CHECK (reasoning_format IS NULL OR reasoning_format IN (
        'native', 'openai-effort-toggle-off', 'openrouter-effort',
        'zai-toggle', 'qwen-thinking', 'anthropic-adaptive'
    )),
    CHECK (reasoning_budget_min IS NULL OR (typeof(reasoning_budget_min) = 'integer' AND reasoning_budget_min BETWEEN -1 AND 9007199254740991)),
    CHECK (reasoning_budget_max IS NULL OR (typeof(reasoning_budget_max) = 'integer' AND reasoning_budget_max BETWEEN 0 AND 9007199254740991)),
    CHECK (reasoning_budget_min IS NULL OR reasoning_budget_max IS NULL OR reasoning_budget_min <= reasoning_budget_max),
    CHECK (supports_vision IS NULL OR (typeof(supports_vision) = 'integer' AND supports_vision IN (0, 1))),
    CHECK (supports_tools  IS NULL OR (typeof(supports_tools)  = 'integer' AND supports_tools  IN (0, 1))),
    CHECK (cost_input       IS NULL OR (typeof(cost_input)       = 'real' AND cost_input       >= 0)),
    CHECK (cost_output      IS NULL OR (typeof(cost_output)      = 'real' AND cost_output      >= 0)),
    CHECK (cost_cache_read  IS NULL OR (typeof(cost_cache_read)  = 'real' AND cost_cache_read  >= 0)),
    CHECK (cost_cache_write IS NULL OR (typeof(cost_cache_write) = 'real' AND cost_cache_write >= 0)),
    CHECK (
        (kind = 'model' AND
            upstream_id IS NOT NULL AND name IS NOT NULL AND
            context_window IS NOT NULL AND max_output_tokens IS NOT NULL AND
            base_url IS NOT NULL AND protocol IS NOT NULL AND
            supports_temperature IS NOT NULL AND
            reasoning_replay IS NOT NULL AND reasoning_format IS NOT NULL AND
            supports_vision IS NOT NULL AND supports_tools IS NOT NULL AND
            cost_input IS NOT NULL AND cost_output IS NOT NULL AND
            cost_cache_read IS NOT NULL AND cost_cache_write IS NOT NULL) OR
        (kind = 'override' AND source = 'javascript' AND
            upstream_id IS NULL AND name IS NULL AND
            context_window IS NULL AND max_output_tokens IS NULL AND
            base_url IS NULL AND protocol IS NULL AND
            supports_temperature IS NULL AND
            reasoning_replay IS NULL AND reasoning_format IS NULL AND
            reasoning_budget_min IS NULL AND reasoning_budget_max IS NULL AND
            supports_vision IS NULL AND supports_tools IS NULL AND
            cost_input IS NULL AND cost_output IS NULL AND
            cost_cache_read IS NULL AND cost_cache_write IS NULL)
    )
) WITHOUT ROWID;

-- Ordered user-facing reasoning controls for either a complete model or an
-- override. The deterministic default is derived on load and is not duplicated.
CREATE TABLE catalog_model_reasoning_levels (
    public_model_id TEXT NOT NULL,
    source          TEXT NOT NULL,
    kind            TEXT NOT NULL,
    ordinal         INTEGER NOT NULL CHECK (typeof(ordinal) = 'integer' AND ordinal BETWEEN 0 AND 31),
    level           TEXT NOT NULL CHECK (
        typeof(level) = 'text' AND
        length(CAST(level AS BLOB)) BETWEEN 1 AND 32
    ),

    PRIMARY KEY (public_model_id, source, kind, ordinal),
    UNIQUE (public_model_id, source, kind, level),
    FOREIGN KEY (public_model_id, source, kind)
        REFERENCES catalog_models(public_model_id, source, kind) ON DELETE CASCADE
) WITHOUT ROWID;

-- Required for per-provider snapshot replacement and source cleanup; the model
-- primary key already serves exact lookup and stable public-id listing.
CREATE INDEX catalog_models_by_provider
    ON catalog_models(provider_id, source, public_model_id, kind);

-- Primary state, not derived: session.summary_changed is Ungated and never reaches the
-- log, so nothing here rebuilds by replay. Carries the id-minting marks too, one row per
-- session, and `origin` flattened from the Session_Origin union with each arm's ids
-- non-null exactly for that arm.
CREATE TABLE sessions (
    id           BLOB PRIMARY KEY CHECK (typeof(id) = 'blob' AND length(id) = 16), -- wire.Session_Id
    workspace_id BLOB NOT NULL    CHECK (typeof(workspace_id) = 'blob' AND length(workspace_id) = 16), -- wire.Workspace_Id

    origin            TEXT NOT NULL CHECK (origin IN ('root', 'child', 'fork', 'cron')),
    parent_id         BLOB    CHECK (parent_id IS NULL OR (typeof(parent_id) = 'blob' AND length(parent_id) = 16)), -- wire.Session_Id
    parent_message_id INTEGER CHECK (parent_message_id IS NULL OR parent_message_id BETWEEN 1 AND 9007199254740991), -- wire.Message_Id
    parent_part_id    INTEGER CHECK (parent_part_id IS NULL OR parent_part_id BETWEEN 0 AND 9007199254740991), -- wire.Part_Id
    source_id         BLOB    CHECK (source_id IS NULL OR (typeof(source_id) = 'blob' AND length(source_id) = 16)), -- wire.Session_Id
    job_id            BLOB    CHECK (job_id IS NULL OR (typeof(job_id) = 'blob' AND length(job_id) = 16)), -- wire.Job_Id

    profile    TEXT NOT NULL CHECK (typeof(profile)   = 'text' AND length(profile)   <= 64),
    model      TEXT NOT NULL CHECK (typeof(model)     = 'text' AND length(model)     <= 128),
    reasoning  TEXT NOT NULL CHECK (typeof(reasoning) = 'text' AND length(reasoning) <= 32),
    config_rev INTEGER NOT NULL CHECK (config_rev BETWEEN 0 AND 9007199254740991), -- wire.Config_Rev
    permission TEXT NOT NULL CHECK (permission IN ('strict', 'normal', 'yolo')),
    max_rounds INTEGER CHECK (max_rounds IS NULL OR max_rounds BETWEEN 0 AND 9007199254740991), -- u64
    title      TEXT NOT NULL CHECK (typeof(title) = 'text' AND length(title) <= 256),
    agent      TEXT CHECK (agent IS NULL OR (typeof(agent) = 'text' AND length(agent) <= 64)),

    created_by_name    TEXT CHECK (created_by_name    IS NULL OR (typeof(created_by_name)    = 'text' AND length(created_by_name)    <= 64)),
    created_by_version TEXT CHECK (created_by_version IS NULL OR (typeof(created_by_version) = 'text' AND length(created_by_version) <= 32)),

    message_count INTEGER NOT NULL DEFAULT 0 CHECK (message_count BETWEEN 0 AND 9007199254740991), -- u64
    created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0), -- u64
    updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms >= 0), -- u64

    -- Id-minting marks. Monotonic; only ever raised. Recovery reads these, never
    -- MAX(seq) over events: a truncating rewind would reclaim ids.
    seq_high        INTEGER NOT NULL DEFAULT 0 CHECK (seq_high        BETWEEN 0 AND 9007199254740991),
    message_id_high INTEGER NOT NULL DEFAULT 0 CHECK (message_id_high BETWEEN 0 AND 9007199254740991),
    run_id_high     INTEGER NOT NULL DEFAULT 0 CHECK (run_id_high     BETWEEN 0 AND 9007199254740991),
    input_id_high   INTEGER NOT NULL DEFAULT 0 CHECK (input_id_high   BETWEEN 0 AND 9007199254740991),
    config_rev_high INTEGER NOT NULL DEFAULT 0 CHECK (config_rev_high BETWEEN 0 AND 9007199254740991),

    -- Open-run projection: the run left unclosed at the cut — `run.started` with no
    -- matching `run.done`. All null when idle; `runs_apply` maintains them, rebuildable
    -- by replay. `DEFAULT NULL` keeps them out of the full-row insert, like the marks.
    open_run_id            INTEGER DEFAULT NULL CHECK (open_run_id            IS NULL OR open_run_id            BETWEEN 1 AND 9007199254740991), -- wire.Run_Id
    open_run_kind          TEXT    DEFAULT NULL CHECK (open_run_kind          IS NULL OR open_run_kind          IN ('turn', 'compaction')),
    open_run_reason        TEXT    DEFAULT NULL CHECK (open_run_reason        IS NULL OR open_run_reason        IN ('auto', 'manual')),
    open_run_config_rev    INTEGER DEFAULT NULL CHECK (open_run_config_rev    IS NULL OR open_run_config_rev    BETWEEN 0 AND 9007199254740991), -- wire.Config_Rev
    open_run_started_at_ms INTEGER DEFAULT NULL CHECK (open_run_started_at_ms IS NULL OR open_run_started_at_ms >= 0), -- u64

    -- Table constraints follow every column definition; SQLite rejects them interleaved.
    CHECK ((origin = 'child') = (parent_id IS NOT NULL AND parent_message_id IS NOT NULL AND parent_part_id IS NOT NULL)),
    CHECK ((origin = 'fork')  = (source_id IS NOT NULL)),
    CHECK ((origin = 'cron')  = (job_id IS NOT NULL)),
    CHECK ((created_by_name IS NULL) = (created_by_version IS NULL)),
    CHECK (updated_at_ms >= created_at_ms),

    -- Open-run columns move as a unit: all set for an open run, all null when idle,
    -- and `reason` is present exactly for a compaction run.
    CHECK ((open_run_id IS NULL) = (open_run_kind IS NULL)),
    CHECK ((open_run_id IS NULL) = (open_run_config_rev IS NULL)),
    CHECK ((open_run_id IS NULL) = (open_run_started_at_ms IS NULL)),
    CHECK ((open_run_reason IS NOT NULL) = (COALESCE(open_run_kind, '') = 'compaction'))
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
    session_id BLOB NOT NULL -- wire.Session_Id
        CHECK (typeof(session_id) = 'blob' AND length(session_id) = 16)
        REFERENCES sessions(id) ON DELETE CASCADE,
    message_id INTEGER NOT NULL CHECK (message_id BETWEEN 1 AND 9007199254740991), -- wire.Message_Id
    seq        INTEGER NOT NULL CHECK (seq        BETWEEN 1 AND 9007199254740991), -- wire.Seq

    role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'compaction')),
    run_id     INTEGER CHECK (run_id     IS NULL OR run_id     BETWEEN 1 AND 9007199254740991), -- wire.Run_Id
    config_rev INTEGER CHECK (config_rev IS NULL OR config_rev BETWEEN 0 AND 9007199254740991), -- wire.Config_Rev

    -- What answered, from the turn's provenance — not the config_rev it was
    -- requested under. Null until the engine records provenance.
    model    TEXT CHECK (model    IS NULL OR (typeof(model)    = 'text' AND length(model)    <= 128)),
    protocol TEXT CHECK (protocol IS NULL OR (typeof(protocol) = 'text' AND length(protocol) <= 32)),

    finish TEXT CHECK (finish IS NULL OR
        finish IN ('stop', 'length', 'content_filter', 'tool_calls', 'canceled', 'error', 'unknown')),
    tokens_input       INTEGER CHECK (tokens_input       IS NULL OR tokens_input       >= 0), -- u64
    tokens_output      INTEGER CHECK (tokens_output      IS NULL OR tokens_output      >= 0), -- u64
    tokens_reasoning   INTEGER CHECK (tokens_reasoning   IS NULL OR tokens_reasoning   >= 0), -- u64
    tokens_cache_read  INTEGER CHECK (tokens_cache_read  IS NULL OR tokens_cache_read  >= 0), -- u64
    tokens_cache_write INTEGER CHECK (tokens_cache_write IS NULL OR tokens_cache_write >= 0), -- u64
    cost               REAL    CHECK (cost               IS NULL OR cost               >= 0),

    created_at_ms INTEGER NOT NULL CHECK (created_at_ms >= 0), -- u64

    PRIMARY KEY (session_id, message_id)
) WITHOUT ROWID;

-- Partial: no row carries a model until the engine records provenance, so this
-- costs nothing until it is the index that answers "which turns used X".
CREATE INDEX messages_by_model ON messages(model, created_at_ms) WHERE model IS NOT NULL;

-- Projection of `config.changed`, rebuildable by replay. session.config can fetch
-- any past revision, which would otherwise mean folding the log from seq 1.
CREATE TABLE session_configs (
    session_id BLOB NOT NULL -- wire.Session_Id
        CHECK (typeof(session_id) = 'blob' AND length(session_id) = 16)
        REFERENCES sessions(id) ON DELETE CASCADE,
    config_rev INTEGER NOT NULL CHECK (config_rev BETWEEN 0 AND 9007199254740991), -- wire.Config_Rev
    model      TEXT NOT NULL CHECK (typeof(model)     = 'text' AND length(model)     <= 128),
    reasoning  TEXT NOT NULL CHECK (typeof(reasoning) = 'text' AND length(reasoning) <= 32),

    PRIMARY KEY (session_id, config_rev)
) WITHOUT ROWID;

-- Per-session, not per-revision: Create_Session sets it and no method changes it.
-- Kept out of `sessions` because it is @unbounded and that table is WITHOUT ROWID,
-- so a large value would land in the interior nodes session.list scans walk.
-- A missing row is `system_prompt: null`.
CREATE TABLE session_prompts (
    session_id BLOB PRIMARY KEY
        CHECK (typeof(session_id) = 'blob' AND length(session_id) = 16)
        REFERENCES sessions(id) ON DELETE CASCADE,
    prompt TEXT NOT NULL CHECK (typeof(prompt) = 'text')
) WITHOUT ROWID;
