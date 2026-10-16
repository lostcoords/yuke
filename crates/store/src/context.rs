//! The load of a session: its settings, its model context, and its newest turn.

use yuke_sql::rusqlite::{self, Connection};

use yuke_agent::Opened;
use yuke_protocol::SessionId;

use crate::event;
use crate::queries::events;

/// Load session `id` with no lease, or `None` when the database has no such session. The caller runs the load in a
/// transaction, so each query reads the same state.
pub(crate) fn load(connection: &Connection, id: SessionId) -> rusqlite::Result<Option<Opened>> {
    let session = *id.as_bytes();
    // Each session has a settings event, so no row means no session.
    let Some(settings) = events::newest_settings(connection, session).opt()? else {
        return Ok(None);
    };
    // The context starts at the newest replacement: its head, then the blocks that it keeps.
    let mut context = Vec::new();
    let mut first = 0;
    if let Some(replacement) = events::newest_replacement(connection, session).opt()? {
        if let (Some(head), Some(keep)) = (replacement.head, replacement.keep) {
            context = head.0;
            context.append(&mut kept(connection, session, replacement.seq, keep)?);
        }
        first = replacement.seq;
    }
    let rows = events::commits_from(
        connection,
        &events::CommitsFromParams {
            session_id: session,
            first,
        },
    )
    .all()?;
    let mut newest_end = None;
    for row in rows {
        context.extend(required(row.blocks, "blocks")?.0);
        newest_end = Some((row.end_kind, row.end_finish_reason, row.end_message));
    }
    let newest_turn = match newest_end {
        None => yuke_agent::NewestTurn::Empty,
        Some((kind, finish_reason, message)) => event::turn_end(kind.as_deref(), finish_reason, message)?
            .map_or(yuke_agent::NewestTurn::Open, yuke_agent::NewestTurn::Ended),
    };
    Ok(Some(Opened {
        id,
        settings: required(settings.settings, "settings")?.0,
        context,
        newest_turn,
        lease: None,
    }))
}

/// The last `count` blocks of the context before event `before`, oldest first. A context shorter than `count` gives
/// all its blocks.
fn kept(
    connection: &Connection,
    session: [u8; 16],
    mut before: u64,
    mut count: usize,
) -> rusqlite::Result<Vec<yuke_ai::Block>> {
    // The walk goes back over the commits, so it collects the parts newest first. A loop, not a recursion, keeps the
    // stack small when a replacement keeps many blocks.
    let mut parts: Vec<Vec<yuke_ai::Block>> = Vec::new();
    let mut collected = 0;
    // For each replacement on the walk: its head, the number of blocks still missing, and `collected` at that point.
    let mut heads = Vec::new();
    while count > 0 {
        let params = events::PreviousCommitParams {
            session_id: session,
            before,
        };
        let Some(row) = events::previous_commit(connection, &params).opt()? else {
            break;
        };
        let mut blocks = required(row.blocks, "blocks")?.0;
        let part = blocks.split_off(blocks.len().saturating_sub(count));
        count -= part.len();
        collected += part.len();
        parts.push(part);
        // Before its blocks, a replacement commit has its head and at most `keep` earlier blocks.
        if let (Some(head), Some(keep)) = (row.head, row.keep)
            && count > 0
        {
            heads.push((head.0, count, collected));
            count = count.min(keep);
        }
        before = row.seq;
    }
    // Take the replacements in reverse walk order. In the context, the head of an older replacement comes after the
    // head of a newer one.
    while let Some((mut head, missing, collected_before)) = heads.pop() {
        let from_head = missing - (collected - collected_before);
        let part = head.split_off(head.len().saturating_sub(from_head));
        collected += part.len();
        parts.push(part);
    }
    Ok(parts.into_iter().rev().flatten().collect())
}

/// The value of a column that the kind of its row always sets. A missing value means a damaged row.
pub(crate) fn required<T>(value: Option<T>, column: &str) -> rusqlite::Result<T> {
    value.ok_or_else(|| rusqlite::Error::InvalidColumnType(0, column.to_owned(), rusqlite::types::Type::Null))
}
