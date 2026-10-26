//! Generated from the query files by `yuke-sqlgen`. Do not edit.

/// The SQL of each migration in number order. The `user_version` of a database counts its applied migrations.
/// A database at `user_version` `n` runs `MIGRATIONS[n..]`.
pub(crate) const MIGRATIONS: &[&str] = &[include_str!(r"../migrations/0001_sessions.sql")];

pub(crate) mod events {
    use yuke_sql::rusqlite::{Connection, Result};
    use yuke_sql::{Query, execute};

    #[derive(Debug, PartialEq)]
    pub(crate) struct EventsPage {
        pub(crate) seq: u64,
        pub(crate) kind: String,
        pub(crate) blocks: Option<crate::Json<Vec<yuke_ai::Block>>>,
        pub(crate) settings: Option<crate::Json<yuke_protocol::SessionSettings>>,
        pub(crate) consumed: Option<crate::Json<Vec<yuke_protocol::ConsumedInput>>>,
        pub(crate) head: Option<crate::Json<Vec<yuke_ai::Block>>>,
        pub(crate) keep: Option<usize>,
        pub(crate) model: Option<String>,
        pub(crate) base_url: Option<String>,
        pub(crate) input_tokens: Option<u64>,
        pub(crate) output_tokens: Option<u64>,
        pub(crate) reasoning_tokens: Option<u64>,
        pub(crate) cache_read_tokens: Option<u64>,
        pub(crate) cache_write_tokens: Option<u64>,
        pub(crate) finish_reason: Option<String>,
        pub(crate) end_kind: Option<String>,
        pub(crate) end_finish_reason: Option<String>,
        pub(crate) end_message: Option<String>,
    }

    #[derive(Debug, PartialEq)]
    pub(crate) struct NewestReplacement {
        pub(crate) seq: u64,
        pub(crate) head: Option<crate::Json<Vec<yuke_ai::Block>>>,
        pub(crate) keep: Option<usize>,
    }

    #[derive(Debug, PartialEq)]
    pub(crate) struct PreviousCommit {
        pub(crate) seq: u64,
        pub(crate) head: Option<crate::Json<Vec<yuke_ai::Block>>>,
        pub(crate) keep: Option<usize>,
        pub(crate) blocks: Option<crate::Json<Vec<yuke_ai::Block>>>,
    }

    #[derive(Debug, PartialEq)]
    pub(crate) struct CommitsFrom {
        pub(crate) blocks: Option<crate::Json<Vec<yuke_ai::Block>>>,
        pub(crate) end_kind: Option<String>,
        pub(crate) end_finish_reason: Option<String>,
        pub(crate) end_message: Option<String>,
    }

    #[derive(Debug)]
    pub(crate) struct InsertSettingsParams {
        pub(crate) session_id: [u8; 16],
        pub(crate) settings: String,
    }

    /// Add a settings event with the next event number of the session. It adds no row for an unknown session.
    pub(crate) fn insert_settings<'a>(connection: &'a Connection, params: &InsertSettingsParams) -> Query<'a, u64> {
        Query::new(
            connection,
            r"INSERT INTO events(session_id, seq, kind, settings)
SELECT id, (SELECT coalesce(max(seq), 0) + 1 FROM events WHERE session_id = :session_id), 'settings', :settings
FROM sessions WHERE id = :session_id
RETURNING seq;",
            &[(":session_id", &params.session_id), (":settings", &params.settings)],
            |row| row.get("seq"),
        )
    }

    #[derive(Debug)]
    pub(crate) struct InsertCommitParams<'a> {
        pub(crate) session_id: [u8; 16],
        pub(crate) blocks: String,
        pub(crate) consumed: String,
        pub(crate) head: Option<String>,
        pub(crate) keep: Option<usize>,
        pub(crate) model: Option<String>,
        pub(crate) base_url: Option<String>,
        pub(crate) input_tokens: Option<u64>,
        pub(crate) output_tokens: Option<u64>,
        pub(crate) reasoning_tokens: Option<u64>,
        pub(crate) cache_read_tokens: Option<u64>,
        pub(crate) cache_write_tokens: Option<u64>,
        pub(crate) finish_reason: Option<&'a str>,
        pub(crate) end_kind: Option<&'a str>,
        pub(crate) end_finish_reason: Option<&'a str>,
        pub(crate) end_message: Option<String>,
    }

    /// Add a commit event with the next event number of the session. It adds no row for an unknown session.
    pub(crate) fn insert_commit<'a>(connection: &'a Connection, params: &InsertCommitParams<'_>) -> Query<'a, u64> {
        Query::new(
            connection,
            r"INSERT INTO events(
    session_id, seq, kind, blocks, consumed, head, keep, model, base_url, input_tokens, output_tokens,
    reasoning_tokens, cache_read_tokens, cache_write_tokens, finish_reason, end_kind, end_finish_reason, end_message
)
SELECT
    id, (SELECT coalesce(max(seq), 0) + 1 FROM events WHERE session_id = :session_id), 'commit', :blocks, :consumed,
    :head, :keep, :model, :base_url, :input_tokens, :output_tokens, :reasoning_tokens, :cache_read_tokens,
    :cache_write_tokens, :finish_reason, :end_kind, :end_finish_reason, :end_message
FROM sessions WHERE id = :session_id
RETURNING seq;",
            &[
                (":session_id", &params.session_id),
                (":blocks", &params.blocks),
                (":consumed", &params.consumed),
                (":head", &params.head),
                (":keep", &params.keep),
                (":model", &params.model),
                (":base_url", &params.base_url),
                (":input_tokens", &params.input_tokens),
                (":output_tokens", &params.output_tokens),
                (":reasoning_tokens", &params.reasoning_tokens),
                (":cache_read_tokens", &params.cache_read_tokens),
                (":cache_write_tokens", &params.cache_write_tokens),
                (":finish_reason", &params.finish_reason),
                (":end_kind", &params.end_kind),
                (":end_finish_reason", &params.end_finish_reason),
                (":end_message", &params.end_message),
            ],
            |row| row.get("seq"),
        )
    }

    /// The newest event number that a fork with no `through` copies: the end of the newest completed turn. With no completed
    /// turn, it is the event before the first commit, or the newest event when the session has no commit. It returns no row
    /// for an unknown session.
    pub(crate) fn fork_cut(connection: &Connection, id: [u8; 16]) -> Query<'_, u64> {
        Query::new(
            connection,
            r"SELECT coalesce(
    (SELECT max(seq) FROM events WHERE session_id = :id AND kind = 'commit' AND end_kind = 'completed'),
    (SELECT min(seq) - 1 FROM events WHERE session_id = :id AND kind = 'commit'),
    (SELECT max(seq) FROM events WHERE session_id = :id)
) AS cut
FROM sessions WHERE id = :id;",
            &[(":id", &id)],
            |row| row.get("cut"),
        )
    }

    #[derive(Debug)]
    pub(crate) struct EndsCompletedTurnParams {
        pub(crate) session_id: [u8; 16],
        pub(crate) seq: u64,
    }

    /// Whether the commit with this number in this session ends a completed turn.
    pub(crate) fn ends_completed_turn<'a>(
        connection: &'a Connection,
        params: &EndsCompletedTurnParams,
    ) -> Query<'a, bool> {
        Query::new(
            connection,
            r"SELECT EXISTS(
  SELECT 1 FROM events
  WHERE session_id = :session_id AND seq = :seq AND kind = 'commit' AND end_kind = 'completed'
) AS present;",
            &[(":session_id", &params.session_id), (":seq", &params.seq)],
            |row| row.get("present"),
        )
    }

    #[derive(Debug)]
    pub(crate) struct CopyEventsParams {
        pub(crate) source: [u8; 16],
        pub(crate) session_id: [u8; 16],
        pub(crate) cut: u64,
    }

    /// Copy each event of session `source` up to event `cut` to session `session_id` with its number, its token usage, and
    /// its creation time.
    pub(crate) fn copy_events(connection: &Connection, params: &CopyEventsParams) -> Result<usize> {
        execute(
            connection,
            r"INSERT INTO events(
    session_id, seq, kind, blocks, settings, consumed, head, keep, model, base_url, input_tokens, output_tokens,
    reasoning_tokens, cache_read_tokens, cache_write_tokens, finish_reason, end_kind, end_finish_reason, end_message,
    created_at
)
SELECT
    :session_id, seq, kind, blocks, settings, consumed, head, keep, model, base_url, input_tokens, output_tokens,
    reasoning_tokens, cache_read_tokens, cache_write_tokens, finish_reason, end_kind, end_finish_reason, end_message,
    created_at
FROM events WHERE session_id = :source AND seq <= :cut
ORDER BY seq;",
            &[
                (":source", &params.source),
                (":session_id", &params.session_id),
                (":cut", &params.cut),
            ],
        )
    }

    #[derive(Debug)]
    pub(crate) struct EventsPageParams {
        pub(crate) session_id: [u8; 16],
        pub(crate) after: u64,
        pub(crate) before: u64,
        pub(crate) limit: i64,
    }

    /// The last `limit` events of the session with a number above `after` and below `before`, in number order. A
    /// negative `limit` takes each matching event.
    pub(crate) fn events_page<'a>(connection: &'a Connection, params: &EventsPageParams) -> Query<'a, EventsPage> {
        Query::new(
            connection,
            r"SELECT
    seq, kind, blocks, settings, consumed, head, keep, model, base_url, input_tokens, output_tokens, reasoning_tokens,
    cache_read_tokens, cache_write_tokens, finish_reason, end_kind, end_finish_reason, end_message
FROM (
    SELECT
        seq, kind, blocks, settings, consumed, head, keep, model, base_url, input_tokens, output_tokens,
        reasoning_tokens, cache_read_tokens, cache_write_tokens, finish_reason, end_kind, end_finish_reason, end_message
    FROM events WHERE session_id = :session_id AND seq > :after AND seq < :before
    ORDER BY seq DESC LIMIT :limit
)
ORDER BY seq;",
            &[
                (":session_id", &params.session_id),
                (":after", &params.after),
                (":before", &params.before),
                (":limit", &params.limit),
            ],
            |row| {
                Ok(EventsPage {
                    seq: row.get("seq")?,
                    kind: row.get("kind")?,
                    blocks: row.get("blocks")?,
                    settings: row.get("settings")?,
                    consumed: row.get("consumed")?,
                    head: row.get("head")?,
                    keep: row.get("keep")?,
                    model: row.get("model")?,
                    base_url: row.get("base_url")?,
                    input_tokens: row.get("input_tokens")?,
                    output_tokens: row.get("output_tokens")?,
                    reasoning_tokens: row.get("reasoning_tokens")?,
                    cache_read_tokens: row.get("cache_read_tokens")?,
                    cache_write_tokens: row.get("cache_write_tokens")?,
                    finish_reason: row.get("finish_reason")?,
                    end_kind: row.get("end_kind")?,
                    end_finish_reason: row.get("end_finish_reason")?,
                    end_message: row.get("end_message")?,
                })
            },
        )
    }

    /// The settings of the newest settings event of the session. It returns no row for an unknown session.
    pub(crate) fn newest_settings(
        connection: &Connection,
        session_id: [u8; 16],
    ) -> Query<'_, Option<crate::Json<yuke_protocol::SessionSettings>>> {
        Query::new(
            connection,
            r"SELECT settings FROM events
WHERE session_id = :session_id AND kind = 'settings'
ORDER BY seq DESC LIMIT 1;",
            &[(":session_id", &session_id)],
            |row| row.get("settings"),
        )
    }

    /// The input tokens of the newest answer of the session. It returns no row without an answer or a replacement. It
    pub(crate) fn newest_input_tokens(connection: &Connection, session_id: [u8; 16]) -> Query<'_, Option<u64>> {
        Query::new(
            connection,
            r"-- returns NULL after a newer replacement, because a replacement row has no usage.
SELECT input_tokens FROM events
WHERE session_id = :session_id AND kind = 'commit' AND (model IS NOT NULL OR keep IS NOT NULL)
ORDER BY seq DESC LIMIT 1;",
            &[(":session_id", &session_id)],
            |row| row.get("input_tokens"),
        )
    }

    /// The newest commit of the session with a replacement.
    pub(crate) fn newest_replacement(connection: &Connection, session_id: [u8; 16]) -> Query<'_, NewestReplacement> {
        Query::new(
            connection,
            r"SELECT seq, head, keep FROM events
WHERE session_id = :session_id AND kind = 'commit' AND keep IS NOT NULL
ORDER BY seq DESC LIMIT 1;",
            &[(":session_id", &session_id)],
            |row| {
                Ok(NewestReplacement {
                    seq: row.get("seq")?,
                    head: row.get("head")?,
                    keep: row.get("keep")?,
                })
            },
        )
    }

    #[derive(Debug)]
    pub(crate) struct PreviousCommitParams {
        pub(crate) session_id: [u8; 16],
        pub(crate) before: u64,
    }

    /// The newest commit of the session before event `before`.
    pub(crate) fn previous_commit<'a>(
        connection: &'a Connection,
        params: &PreviousCommitParams,
    ) -> Query<'a, PreviousCommit> {
        Query::new(
            connection,
            r"SELECT seq, head, keep, blocks FROM events
WHERE session_id = :session_id AND kind = 'commit' AND seq < :before
ORDER BY seq DESC LIMIT 1;",
            &[(":session_id", &params.session_id), (":before", &params.before)],
            |row| {
                Ok(PreviousCommit {
                    seq: row.get("seq")?,
                    head: row.get("head")?,
                    keep: row.get("keep")?,
                    blocks: row.get("blocks")?,
                })
            },
        )
    }

    #[derive(Debug)]
    pub(crate) struct CommitsFromParams {
        pub(crate) session_id: [u8; 16],
        pub(crate) first: u64,
    }

    /// The commits of the session from event `first` on, oldest first.
    pub(crate) fn commits_from<'a>(connection: &'a Connection, params: &CommitsFromParams) -> Query<'a, CommitsFrom> {
        Query::new(
            connection,
            r"SELECT blocks, end_kind, end_finish_reason, end_message FROM events
WHERE session_id = :session_id AND kind = 'commit' AND seq >= :first
ORDER BY seq;",
            &[(":session_id", &params.session_id), (":first", &params.first)],
            |row| {
                Ok(CommitsFrom {
                    blocks: row.get("blocks")?,
                    end_kind: row.get("end_kind")?,
                    end_finish_reason: row.get("end_finish_reason")?,
                    end_message: row.get("end_message")?,
                })
            },
        )
    }
}

pub(crate) mod pending_inputs {
    use yuke_sql::rusqlite::{Connection, Result};
    use yuke_sql::{Query, execute};

    #[derive(Debug, PartialEq)]
    pub(crate) struct PendingInputs {
        pub(crate) id: u64,
        pub(crate) input: crate::Json<yuke_protocol::Input>,
    }

    #[derive(Debug)]
    pub(crate) struct InsertPendingInputParams {
        pub(crate) session_id: [u8; 16],
        pub(crate) input: String,
    }

    /// Add a pending input to the session, and return its id. It adds no row for an unknown session.
    pub(crate) fn insert_pending_input<'a>(
        connection: &'a Connection,
        params: &InsertPendingInputParams,
    ) -> Query<'a, u64> {
        Query::new(
            connection,
            r"INSERT INTO pending_inputs(session_id, input)
SELECT id, :input FROM sessions WHERE id = :session_id
RETURNING id;",
            &[(":session_id", &params.session_id), (":input", &params.input)],
            |row| row.get("id"),
        )
    }

    pub(crate) fn pending_inputs(connection: &Connection, session_id: [u8; 16]) -> Query<'_, PendingInputs> {
        Query::new(
            connection,
            r"SELECT id, input FROM pending_inputs WHERE session_id = :session_id ORDER BY id;",
            &[(":session_id", &session_id)],
            |row| {
                Ok(PendingInputs {
                    id: row.get("id")?,
                    input: row.get("input")?,
                })
            },
        )
    }

    #[derive(Debug)]
    pub(crate) struct DeletePendingInputParams {
        pub(crate) session_id: [u8; 16],
        pub(crate) id: u64,
    }

    pub(crate) fn delete_pending_input(connection: &Connection, params: &DeletePendingInputParams) -> Result<usize> {
        execute(
            connection,
            r"DELETE FROM pending_inputs WHERE session_id = :session_id AND id = :id;",
            &[(":session_id", &params.session_id), (":id", &params.id)],
        )
    }
}

pub(crate) mod sessions {
    use yuke_sql::rusqlite::{Connection, Result};
    use yuke_sql::{Query, execute};

    #[derive(Debug, PartialEq)]
    pub(crate) struct ListSessions {
        pub(crate) id: [u8; 16],
        pub(crate) settings: crate::Json<yuke_protocol::SessionSettings>,
        pub(crate) preview: Option<String>,
        pub(crate) fork_of: Option<[u8; 16]>,
        pub(crate) created_at: u64,
        pub(crate) updated_at: u64,
        pub(crate) newest_event: i64,
    }

    #[derive(Debug, PartialEq)]
    pub(crate) struct ListSessionsIn {
        pub(crate) id: [u8; 16],
        pub(crate) settings: crate::Json<yuke_protocol::SessionSettings>,
        pub(crate) preview: Option<String>,
        pub(crate) fork_of: Option<[u8; 16]>,
        pub(crate) created_at: u64,
        pub(crate) updated_at: u64,
        pub(crate) newest_event: i64,
    }

    #[derive(Debug, PartialEq)]
    pub(crate) struct SessionSummary {
        pub(crate) id: [u8; 16],
        pub(crate) settings: crate::Json<yuke_protocol::SessionSettings>,
        pub(crate) preview: Option<String>,
        pub(crate) fork_of: Option<[u8; 16]>,
        pub(crate) created_at: u64,
        pub(crate) updated_at: u64,
    }

    #[derive(Debug)]
    pub(crate) struct InsertSessionParams {
        pub(crate) id: [u8; 16],
        pub(crate) prompt: String,
        pub(crate) settings: String,
    }

    pub(crate) fn insert_session(connection: &Connection, params: &InsertSessionParams) -> Result<usize> {
        execute(
            connection,
            r"INSERT INTO sessions(id, prompt, settings) VALUES (:id, :prompt, :settings);",
            &[
                (":id", &params.id),
                (":prompt", &params.prompt),
                (":settings", &params.settings),
            ],
        )
    }

    #[derive(Debug)]
    pub(crate) struct CopySessionParams {
        pub(crate) source: [u8; 16],
        pub(crate) id: [u8; 16],
        pub(crate) cut: u64,
    }

    /// Add session `id` as a fork of session `source`: its prompt, its preview, and its newest settings at event
    /// `cut`. It adds no row for an unknown source.
    pub(crate) fn copy_session(connection: &Connection, params: &CopySessionParams) -> Result<usize> {
        execute(
            connection,
            r"INSERT INTO sessions(id, prompt, settings, preview, fork_of)
SELECT
    :id, prompt,
    coalesce(
        (SELECT settings FROM events WHERE session_id = :source AND kind = 'settings' AND seq <= :cut
         ORDER BY seq DESC LIMIT 1),
        settings
    ),
    preview, id
FROM sessions WHERE id = :source;",
            &[(":source", &params.source), (":id", &params.id), (":cut", &params.cut)],
        )
    }

    #[derive(Debug)]
    pub(crate) struct SetSessionSettingsParams {
        pub(crate) id: [u8; 16],
        pub(crate) settings: String,
    }

    /// Keep `settings`, the settings of the newest settings event, in the row of the session.
    pub(crate) fn set_session_settings(connection: &Connection, params: &SetSessionSettingsParams) -> Result<usize> {
        execute(
            connection,
            r"UPDATE sessions SET settings = :settings WHERE id = :id;",
            &[(":id", &params.id), (":settings", &params.settings)],
        )
    }

    /// Give the session the time and the id of its newest event.
    pub(crate) fn touch_session(connection: &Connection, id: [u8; 16]) -> Result<usize> {
        execute(
            connection,
            r"UPDATE sessions
SET (updated_at, newest_event) = (
    SELECT created_at, id FROM events WHERE session_id = :id ORDER BY seq DESC LIMIT 1
)
WHERE id = :id;",
            &[(":id", &id)],
        )
    }

    /// Give a new fork the id of its newest event row. Its copied events keep their times, so its updated time
    /// stays its creation time.
    pub(crate) fn place_fork(connection: &Connection, id: [u8; 16]) -> Result<usize> {
        execute(
            connection,
            r"UPDATE sessions
SET newest_event = (SELECT id FROM events WHERE session_id = :id ORDER BY seq DESC LIMIT 1)
WHERE id = :id;",
            &[(":id", &id)],
        )
    }

    #[derive(Debug)]
    pub(crate) struct SetPreviewParams<'a> {
        pub(crate) id: [u8; 16],
        pub(crate) preview: &'a str,
    }

    /// Give the session the preview `preview` when it has none.
    pub(crate) fn set_preview(connection: &Connection, params: &SetPreviewParams<'_>) -> Result<usize> {
        execute(
            connection,
            r"UPDATE sessions SET preview = :preview WHERE id = :id AND preview IS NULL;",
            &[(":id", &params.id), (":preview", &params.preview)],
        )
    }

    #[derive(Debug)]
    pub(crate) struct ListSessionsParams {
        pub(crate) before: i64,
        pub(crate) limit: usize,
    }

    /// The sessions whose newest event id is below `before`, newest first.
    pub(crate) fn list_sessions<'a>(
        connection: &'a Connection,
        params: &ListSessionsParams,
    ) -> Query<'a, ListSessions> {
        Query::new(
            connection,
            r"SELECT id, settings, preview, fork_of, created_at, updated_at, newest_event FROM sessions
WHERE newest_event < :before
ORDER BY newest_event DESC
LIMIT :limit;",
            &[(":before", &params.before), (":limit", &params.limit)],
            |row| {
                Ok(ListSessions {
                    id: row.get("id")?,
                    settings: row.get("settings")?,
                    preview: row.get("preview")?,
                    fork_of: row.get("fork_of")?,
                    created_at: row.get("created_at")?,
                    updated_at: row.get("updated_at")?,
                    newest_event: row.get("newest_event")?,
                })
            },
        )
    }

    #[derive(Debug)]
    pub(crate) struct ListSessionsInParams<'a> {
        pub(crate) cwd: &'a str,
        pub(crate) before: i64,
        pub(crate) limit: usize,
    }

    /// The sessions of the folder `cwd` whose newest event id is below `before`, newest first.
    pub(crate) fn list_sessions_in<'a>(
        connection: &'a Connection,
        params: &ListSessionsInParams<'_>,
    ) -> Query<'a, ListSessionsIn> {
        Query::new(
            connection,
            r"SELECT id, settings, preview, fork_of, created_at, updated_at, newest_event FROM sessions
WHERE cwd = :cwd AND newest_event < :before
ORDER BY newest_event DESC
LIMIT :limit;",
            &[
                (":cwd", &params.cwd),
                (":before", &params.before),
                (":limit", &params.limit),
            ],
            |row| {
                Ok(ListSessionsIn {
                    id: row.get("id")?,
                    settings: row.get("settings")?,
                    preview: row.get("preview")?,
                    fork_of: row.get("fork_of")?,
                    created_at: row.get("created_at")?,
                    updated_at: row.get("updated_at")?,
                    newest_event: row.get("newest_event")?,
                })
            },
        )
    }

    /// The saved facts for `session/list` and `session/get`. It returns no row for an unknown session.
    pub(crate) fn session_summary(connection: &Connection, id: [u8; 16]) -> Query<'_, SessionSummary> {
        Query::new(
            connection,
            r"SELECT id, settings, preview, fork_of, created_at, updated_at FROM sessions WHERE id = :id;",
            &[(":id", &id)],
            |row| {
                Ok(SessionSummary {
                    id: row.get("id")?,
                    settings: row.get("settings")?,
                    preview: row.get("preview")?,
                    fork_of: row.get("fork_of")?,
                    created_at: row.get("created_at")?,
                    updated_at: row.get("updated_at")?,
                })
            },
        )
    }

    /// The sections of the system prompt of the session. It returns no row for an unknown session.
    pub(crate) fn session_prompt(
        connection: &Connection,
        id: [u8; 16],
    ) -> Query<'_, crate::Json<Vec<yuke_agent::PromptSection>>> {
        Query::new(
            connection,
            r"SELECT prompt FROM sessions WHERE id = :id;",
            &[(":id", &id)],
            |row| row.get("prompt"),
        )
    }

    /// Whether a session has this id.
    pub(crate) fn session_exists(connection: &Connection, id: [u8; 16]) -> Query<'_, bool> {
        Query::new(
            connection,
            r"SELECT EXISTS(SELECT 1 FROM sessions WHERE id = :id) AS present;",
            &[(":id", &id)],
            |row| row.get("present"),
        )
    }

    /// Delete the session. The cascade deletes its events and its pending inputs.
    pub(crate) fn delete_session(connection: &Connection, id: [u8; 16]) -> Result<usize> {
        execute(connection, r"DELETE FROM sessions WHERE id = :id;", &[(":id", &id)])
    }
}
