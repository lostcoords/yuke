//! Generated from the query files by `yuke-sqlgen`. Do not edit.

use super::*;

/// The SQL of each migration in number order. The `user_version` of a database counts its applied migrations.
/// A database at `user_version` `n` runs `MIGRATIONS[n..]`.
pub(crate) const MIGRATIONS: &[&str] = &[include_str!(r"../migrations/0001_sessions.sql")];

pub(crate) mod commits {
    use super::*;
    use yuke_sql::rusqlite::{Connection, Result, Row};
    use yuke_sql::{FromRow, Query, execute};

    #[derive(Debug, Clone, PartialEq)]
    pub(crate) struct NewestReplacement {
        pub(crate) id: i64,
        pub(crate) head: Option<Json<Vec<yuke_ai::Block>>>,
        pub(crate) keep: Option<usize>,
    }

    impl FromRow for NewestReplacement {
        fn from_row(row: &Row<'_>) -> Result<Self> {
            Ok(Self {
                id: row.get("id")?,
                head: row.get("head")?,
                keep: row.get("keep")?,
            })
        }
    }

    #[derive(Debug, Clone, PartialEq)]
    pub(crate) struct PreviousCommit {
        pub(crate) id: i64,
        pub(crate) head: Option<Json<Vec<yuke_ai::Block>>>,
        pub(crate) keep: Option<usize>,
        pub(crate) blocks: Json<Vec<yuke_ai::Block>>,
    }

    impl FromRow for PreviousCommit {
        fn from_row(row: &Row<'_>) -> Result<Self> {
            Ok(Self {
                id: row.get("id")?,
                head: row.get("head")?,
                keep: row.get("keep")?,
                blocks: row.get("blocks")?,
            })
        }
    }

    #[derive(Debug, Clone, PartialEq)]
    pub(crate) struct CommitsFrom {
        pub(crate) blocks: Json<Vec<yuke_ai::Block>>,
        pub(crate) end_kind: Option<String>,
    }

    impl FromRow for CommitsFrom {
        fn from_row(row: &Row<'_>) -> Result<Self> {
            Ok(Self {
                blocks: row.get("blocks")?,
                end_kind: row.get("end_kind")?,
            })
        }
    }

    #[derive(Debug)]
    pub(crate) struct InsertCommitParams {
        pub(crate) session_id: [u8; 16],
        pub(crate) head: Option<String>,
        pub(crate) keep: Option<usize>,
        pub(crate) blocks: String,
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

    /// Add a commit after the commits of the session. It adds no row for an unknown session.
    pub(crate) fn insert_commit(connection: &Connection, params: &InsertCommitParams) -> Result<usize> {
        execute(
            connection,
            r"INSERT INTO commits(
    session_id, head, keep, blocks, model, base_url, input_tokens, output_tokens, reasoning_tokens,
    cache_read_tokens, cache_write_tokens, finish_reason, end_kind, end_finish_reason, end_message
)
SELECT
    id, :head, :keep, :blocks, :model, :base_url, :input_tokens, :output_tokens, :reasoning_tokens,
    :cache_read_tokens, :cache_write_tokens, :finish_reason, :end_kind, :end_finish_reason, :end_message
FROM sessions WHERE id = :session_id;",
            &[
                (":session_id", &params.session_id),
                (":head", &params.head),
                (":keep", &params.keep),
                (":blocks", &params.blocks),
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
        )
    }

    #[derive(Debug)]
    pub(crate) struct CopyCommitsParams {
        pub(crate) source: [u8; 16],
        pub(crate) session_id: [u8; 16],
    }

    /// Copy each commit of session `source` to session `session_id` in id order, with its token usage and its creation time.
    pub(crate) fn copy_commits(connection: &Connection, params: &CopyCommitsParams) -> Result<usize> {
        execute(
            connection,
            r"INSERT INTO commits(
    session_id, head, keep, blocks, model, base_url, input_tokens, output_tokens, reasoning_tokens,
    cache_read_tokens, cache_write_tokens, finish_reason, end_kind, end_finish_reason, end_message, created_at
)
SELECT
    :session_id, head, keep, blocks, model, base_url, input_tokens, output_tokens, reasoning_tokens,
    cache_read_tokens, cache_write_tokens, finish_reason, end_kind, end_finish_reason, end_message, created_at
FROM commits WHERE session_id = :source
ORDER BY id;",
            &[(":source", &params.source), (":session_id", &params.session_id)],
        )
    }

    /// The newest commit of the session with a replacement.
    pub(crate) fn newest_replacement(connection: &Connection, session_id: [u8; 16]) -> Query<'_, NewestReplacement> {
        Query::new(
            connection,
            r"SELECT id, head, keep FROM commits
WHERE session_id = :session_id AND keep IS NOT NULL
ORDER BY id DESC LIMIT 1;",
            &[(":session_id", &session_id)],
        )
    }

    #[derive(Debug)]
    pub(crate) struct PreviousCommitParams {
        pub(crate) session_id: [u8; 16],
        pub(crate) before: i64,
    }

    /// The newest commit of the session before commit `before`.
    pub(crate) fn previous_commit<'a>(
        connection: &'a Connection,
        params: &PreviousCommitParams,
    ) -> Query<'a, PreviousCommit> {
        Query::new(
            connection,
            r"SELECT id, head, keep, blocks FROM commits
WHERE session_id = :session_id AND id < :before
ORDER BY id DESC LIMIT 1;",
            &[(":session_id", &params.session_id), (":before", &params.before)],
        )
    }

    #[derive(Debug)]
    pub(crate) struct CommitsFromParams {
        pub(crate) session_id: [u8; 16],
        pub(crate) first: i64,
    }

    /// The commits of the session from commit `first` on, oldest first.
    pub(crate) fn commits_from<'a>(connection: &'a Connection, params: &CommitsFromParams) -> Query<'a, CommitsFrom> {
        Query::new(
            connection,
            r"SELECT blocks, end_kind FROM commits
WHERE session_id = :session_id AND id >= :first
ORDER BY id;",
            &[(":session_id", &params.session_id), (":first", &params.first)],
        )
    }
}

pub(crate) mod pending_inputs {
    use super::*;
    use yuke_sql::rusqlite::{Connection, Result, Row};
    use yuke_sql::{FromRow, Query, execute};

    #[derive(Debug, Clone, PartialEq)]
    pub(crate) struct InsertPendingInput {
        pub(crate) id: i64,
    }

    impl FromRow for InsertPendingInput {
        fn from_row(row: &Row<'_>) -> Result<Self> {
            Ok(Self { id: row.get("id")? })
        }
    }

    #[derive(Debug, Clone, PartialEq)]
    pub(crate) struct PendingInputs {
        pub(crate) id: i64,
        pub(crate) blocks: Json<Vec<yuke_ai::Block>>,
    }

    impl FromRow for PendingInputs {
        fn from_row(row: &Row<'_>) -> Result<Self> {
            Ok(Self {
                id: row.get("id")?,
                blocks: row.get("blocks")?,
            })
        }
    }

    #[derive(Debug)]
    pub(crate) struct InsertPendingInputParams {
        pub(crate) session_id: [u8; 16],
        pub(crate) blocks: String,
    }

    /// Add a pending input to the session, and return its id. It adds no row for an unknown session.
    pub(crate) fn insert_pending_input<'a>(
        connection: &'a Connection,
        params: &InsertPendingInputParams,
    ) -> Query<'a, InsertPendingInput> {
        Query::new(
            connection,
            r"INSERT INTO pending_inputs(session_id, blocks)
SELECT id, :blocks FROM sessions WHERE id = :session_id
RETURNING id;",
            &[(":session_id", &params.session_id), (":blocks", &params.blocks)],
        )
    }

    pub(crate) fn pending_inputs(connection: &Connection, session_id: [u8; 16]) -> Query<'_, PendingInputs> {
        Query::new(
            connection,
            r"SELECT id, blocks FROM pending_inputs WHERE session_id = :session_id ORDER BY id;",
            &[(":session_id", &session_id)],
        )
    }

    #[derive(Debug)]
    pub(crate) struct DeletePendingInputParams {
        pub(crate) session_id: [u8; 16],
        pub(crate) id: i64,
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
    use super::*;
    use yuke_sql::rusqlite::{Connection, Result, Row};
    use yuke_sql::{FromRow, Query, execute};

    #[derive(Debug, Clone, PartialEq)]
    pub(crate) struct SessionSettings {
        pub(crate) settings: Json<yuke_agent::SessionSettings>,
    }

    impl FromRow for SessionSettings {
        fn from_row(row: &Row<'_>) -> Result<Self> {
            Ok(Self {
                settings: row.get("settings")?,
            })
        }
    }

    #[derive(Debug, Clone, PartialEq)]
    pub(crate) struct SessionCount {
        pub(crate) count: i64,
    }

    impl FromRow for SessionCount {
        fn from_row(row: &Row<'_>) -> Result<Self> {
            Ok(Self {
                count: row.get("count")?,
            })
        }
    }

    #[derive(Debug)]
    pub(crate) struct InsertSessionParams {
        pub(crate) id: [u8; 16],
        pub(crate) settings: String,
    }

    pub(crate) fn insert_session(connection: &Connection, params: &InsertSessionParams) -> Result<usize> {
        execute(
            connection,
            r"INSERT INTO sessions(id, settings) VALUES (:id, :settings);",
            &[(":id", &params.id), (":settings", &params.settings)],
        )
    }

    #[derive(Debug)]
    pub(crate) struct CopySessionParams {
        pub(crate) source: [u8; 16],
        pub(crate) id: [u8; 16],
    }

    /// Add session `id` with the settings of session `source`. It adds no row for an unknown source.
    pub(crate) fn copy_session(connection: &Connection, params: &CopySessionParams) -> Result<usize> {
        execute(
            connection,
            r"INSERT INTO sessions(id, settings) SELECT :id, settings FROM sessions WHERE id = :source;",
            &[(":source", &params.source), (":id", &params.id)],
        )
    }

    #[derive(Debug)]
    pub(crate) struct UpdateSettingsParams {
        pub(crate) id: [u8; 16],
        pub(crate) settings: String,
    }

    /// Replace the settings of the session. It changes no row for an unknown session.
    pub(crate) fn update_settings(connection: &Connection, params: &UpdateSettingsParams) -> Result<usize> {
        execute(
            connection,
            r"UPDATE sessions SET settings = :settings WHERE id = :id;",
            &[(":id", &params.id), (":settings", &params.settings)],
        )
    }

    pub(crate) fn session_settings(connection: &Connection, id: [u8; 16]) -> Query<'_, SessionSettings> {
        Query::new(
            connection,
            r"SELECT settings FROM sessions WHERE id = :id;",
            &[(":id", &id)],
        )
    }

    /// The number of sessions with this id: 0 or 1.
    pub(crate) fn session_count(connection: &Connection, id: [u8; 16]) -> Query<'_, SessionCount> {
        Query::new(
            connection,
            r"SELECT count(*) AS count FROM sessions WHERE id = :id;",
            &[(":id", &id)],
        )
    }

    /// Delete the session. The cascade deletes its commits and its pending inputs.
    pub(crate) fn delete_session(connection: &Connection, id: [u8; 16]) -> Result<usize> {
        execute(connection, r"DELETE FROM sessions WHERE id = :id;", &[(":id", &id)])
    }
}
