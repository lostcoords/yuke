-- The queries of the events table: the numbered commits and settings of each session.

--: Event(seq: u64, kind, blocks?: Json<Vec<yuke_ai::Block>>, settings?: Json<yuke_protocol::SessionSettings>, consumed?: Json<Vec<yuke_protocol::InputId>>, head?: Json<Vec<yuke_ai::Block>>, keep?: usize, model?, base_url?, input_tokens?: u64, output_tokens?: u64, reasoning_tokens?: u64, cache_read_tokens?: u64, cache_write_tokens?: u64, finish_reason?, end_kind?, end_finish_reason?, end_message?)

--! insert_settings (session_id: [u8; 16], settings: String)
--- Add a settings event with the next event number of the session. It adds no row for an unknown session.
INSERT INTO events(session_id, seq, kind, settings)
SELECT id, (SELECT coalesce(max(seq), 0) + 1 FROM events WHERE session_id = :session_id), 'settings', :settings
FROM sessions WHERE id = :session_id;

--! insert_commit (session_id: [u8; 16], blocks: String, consumed: String, head?: String, keep?: usize, model?: String, base_url?: String, input_tokens?: u64, output_tokens?: u64, reasoning_tokens?: u64, cache_read_tokens?: u64, cache_write_tokens?: u64, finish_reason?: String, end_kind?: String, end_finish_reason?: String, end_message?: String) : (seq: u64)
--- Add a commit event with the next event number of the session. It adds no row for an unknown session.
INSERT INTO events(
    session_id, seq, kind, blocks, consumed, head, keep, model, base_url, input_tokens, output_tokens,
    reasoning_tokens, cache_read_tokens, cache_write_tokens, finish_reason, end_kind, end_finish_reason, end_message
)
SELECT
    id, (SELECT coalesce(max(seq), 0) + 1 FROM events WHERE session_id = :session_id), 'commit', :blocks, :consumed,
    :head, :keep, :model, :base_url, :input_tokens, :output_tokens, :reasoning_tokens, :cache_read_tokens,
    :cache_write_tokens, :finish_reason, :end_kind, :end_finish_reason, :end_message
FROM sessions WHERE id = :session_id
RETURNING seq;

--! fork_cut (id: [u8; 16]) : (cut: u64)
--- The newest event number that a fork with no `through` copies: the end of the newest completed turn. With no completed
--- turn, it is the event before the first commit, or the newest event when the session has no commit. It returns no row
--- for an unknown session.
SELECT coalesce(
    (SELECT max(seq) FROM events WHERE session_id = :id AND kind = 'commit' AND end_kind = 'completed'),
    (SELECT min(seq) - 1 FROM events WHERE session_id = :id AND kind = 'commit'),
    (SELECT max(seq) FROM events WHERE session_id = :id)
) AS cut
FROM sessions WHERE id = :id;

--! completed_turn_count (session_id: [u8; 16], seq: u64) : (count: i64)
--- The number of commits with this number that end a completed turn: 0 or 1.
SELECT count(*) AS count FROM events
WHERE session_id = :session_id AND seq = :seq AND kind = 'commit' AND end_kind = 'completed';

--! copy_events (source: [u8; 16], session_id: [u8; 16], cut: u64)
--- Copy each event of session `source` up to event `cut` to session `session_id` with its number, its token usage, and
--- its creation time.
INSERT INTO events(
    session_id, seq, kind, blocks, settings, consumed, head, keep, model, base_url, input_tokens, output_tokens,
    reasoning_tokens, cache_read_tokens, cache_write_tokens, finish_reason, end_kind, end_finish_reason, end_message,
    created_at
)
SELECT
    :session_id, seq, kind, blocks, settings, consumed, head, keep, model, base_url, input_tokens, output_tokens,
    reasoning_tokens, cache_read_tokens, cache_write_tokens, finish_reason, end_kind, end_finish_reason, end_message,
    created_at
FROM events WHERE session_id = :source AND seq <= :cut
ORDER BY seq;

--! events_after (session_id: [u8; 16], after: u64) : Event
--- The events of the session with a number above `after`, in number order.
SELECT
    seq, kind, blocks, settings, consumed, head, keep, model, base_url, input_tokens, output_tokens, reasoning_tokens,
    cache_read_tokens, cache_write_tokens, finish_reason, end_kind, end_finish_reason, end_message
FROM events WHERE session_id = :session_id AND seq > :after
ORDER BY seq;

--! newest_settings (session_id: [u8; 16]) : (settings?: Json<yuke_protocol::SessionSettings>)
--- The settings of the newest settings event of the session. It returns no row for an unknown session.
SELECT settings FROM events
WHERE session_id = :session_id AND kind = 'settings'
ORDER BY seq DESC LIMIT 1;

--! newest_replacement (session_id: [u8; 16]) : (seq: u64, head?: Json<Vec<yuke_ai::Block>>, keep?: usize)
--- The newest commit of the session with a replacement.
SELECT seq, head, keep FROM events
WHERE session_id = :session_id AND kind = 'commit' AND keep IS NOT NULL
ORDER BY seq DESC LIMIT 1;

--! previous_commit (session_id: [u8; 16], before: u64) : (seq: u64, head?: Json<Vec<yuke_ai::Block>>, keep?: usize, blocks?: Json<Vec<yuke_ai::Block>>)
--- The newest commit of the session before event `before`.
SELECT seq, head, keep, blocks FROM events
WHERE session_id = :session_id AND kind = 'commit' AND seq < :before
ORDER BY seq DESC LIMIT 1;

--! commits_from (session_id: [u8; 16], first: u64) : (blocks?: Json<Vec<yuke_ai::Block>>, end_kind?)
--- The commits of the session from event `first` on, oldest first.
SELECT blocks, end_kind FROM events
WHERE session_id = :session_id AND kind = 'commit' AND seq >= :first
ORDER BY seq;

--! newest_session_in (cwd: &str) : (id: [u8; 16])
--- The session whose newest settings event names the folder `cwd` and that has the newest event of those sessions. A
--- new event row gets a rowid above each rowid in the table, so a larger rowid is a newer event.
SELECT settings_event.session_id AS id FROM events AS settings_event
WHERE settings_event.kind = 'settings'
    AND settings_event.seq = (
        SELECT max(seq) FROM events WHERE session_id = settings_event.session_id AND kind = 'settings'
    )
    AND json_extract(settings_event.settings, '$.cwd') = :cwd
ORDER BY (SELECT max(rowid) FROM events WHERE session_id = settings_event.session_id) DESC
LIMIT 1;
