//! The event log of a session: `events.jsonl` in the session folder, one [`StoredEvent`] as JSON on each line. Each
//! line also holds `at`, the millisecond of the write. The first line, the first settings event, also holds the system
//! prompt in a `prompt` field, so a fork copies the prompt with the events and no other file holds it. Line `n` holds
//! event `n`. Only the holder of the lease appends. A reader stops at the last newline, so a torn append of a crash reads
//! as no event. The writer cuts such a tail when it takes the lease. A complete line that is not its event is an error,
//! so a change of the event format does not cut the log.

use std::collections::VecDeque;
use std::fs::{File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use yuke_agent::{EventPage, NewestTurn, PromptSection};
use yuke_engine::{Commit, TurnEnd};
use yuke_protocol::{ConsumedInput, InputId, SessionEvent, SessionSettings, StoredEvent};

/// The name of the log file in a session folder. No blob has this name, because a blob name has 64 characters.
pub(crate) const LOG: &str = "events.jsonl";

/// The path of the log in the session folder `folder`.
pub(crate) fn path(folder: &Path) -> PathBuf {
    folder.join(LOG)
}

/// The events of the log and the end of the line of each. A missing file has no event. A complete line that is not
/// its event is an error.
pub(crate) fn read(folder: &Path) -> io::Result<Log> {
    let mut log = Log {
        events: Vec::new(),
        ends: Vec::new(),
        prompt: Vec::new(),
    };
    lines(folder, |line, end| {
        let event = parse(line, log.events.len() as u64 + 1)?;
        if log.events.is_empty() {
            log.prompt = serde_json::from_slice::<FirstLine>(line)?.prompt;
        }
        log.events.push(event);
        log.ends.push(end);
        Ok(())
    })?;
    Ok(log)
}

/// The events of `page`, and with `pending` the ids of the inputs that the newest event consumed. Only the lines of the
/// page become events, so a short page of a long log parses few lines.
pub(crate) fn page(folder: &Path, page: EventPage, pending: bool) -> io::Result<(Vec<StoredEvent>, Vec<InputId>)> {
    let (after, before, limit) = match page {
        EventPage::After(after) => (after.map_or(0, |number| number.0), u64::MAX, usize::MAX),
        EventPage::Before { before, limit } => (0, before.map_or(u64::MAX, |number| number.0), limit),
    };
    let mut lines_of_page: VecDeque<(u64, Vec<u8>)> = VecDeque::new();
    let mut newest = Vec::new();
    let mut seq = 0;
    lines(folder, |line, _| {
        seq += 1;
        if seq > after && seq < before && limit > 0 {
            if lines_of_page.len() == limit {
                lines_of_page.pop_front();
            }
            lines_of_page.push_back((seq, line.to_vec()));
        }
        if pending {
            newest.clear();
            newest.extend_from_slice(line);
        }
        Ok(())
    })?;
    let events = lines_of_page
        .into_iter()
        .map(|(seq, line)| parse(&line, seq))
        .collect::<io::Result<_>>()?;
    // The writer appends the index line of a turn start right after its log line, so only the newest event can
    // consume an input that the index still holds.
    let consumed = if newest.is_empty() {
        Vec::new()
    } else {
        match parse(&newest, seq)?.event {
            SessionEvent::Commit(commit) => commit.consumed.into_iter().map(|input| input.id).collect(),
            SessionEvent::Settings(_) => Vec::new(),
        }
    };
    Ok((events, consumed))
}

/// Event `seq` from `line`.
fn parse(line: &[u8], seq: u64) -> io::Result<StoredEvent> {
    let event: StoredEvent = serde_json::from_slice(line)?;
    if event.event_number.0 != seq {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("line {seq} of the log holds event {}", event.event_number.0),
        ));
    }
    Ok(event)
}

/// Call `take` with each complete line of the log, without its newline, and the end of the line in the file. Stops at
/// the first error of `take`, and at bytes without a newline.
fn lines(folder: &Path, mut take: impl FnMut(&[u8], u64) -> io::Result<()>) -> io::Result<()> {
    let file = match File::open(path(folder)) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    let mut reader = BufReader::with_capacity(1 << 16, file);
    let mut line = Vec::new();
    let mut end = 0;
    loop {
        line.clear();
        let read = reader.read_until(b'\n', &mut line)?;
        if line.pop() != Some(b'\n') {
            return Ok(());
        }
        end += read as u64;
        take(&line, end)?;
    }
}

/// The field of the first line that is not part of its event.
#[derive(Deserialize)]
struct FirstLine {
    prompt: Vec<PromptSection>,
}

/// The read log of one session.
pub(crate) struct Log {
    /// The events in number order: event `n` is at index `n - 1`.
    pub(crate) events: Vec<StoredEvent>,
    /// The end of the line of each event.
    ends: Vec<u64>,
    /// The system prompt from the first line.
    pub(crate) prompt: Vec<PromptSection>,
}

impl Log {
    /// Events 1 through `cut`, or each event when the log has fewer.
    pub(crate) fn through(&self, cut: u64) -> &[StoredEvent] {
        &self.events[..usize::try_from(cut).unwrap_or(usize::MAX).min(self.events.len())]
    }

    /// The length of the lines of events 1 through `cut`.
    pub(crate) fn prefix_len(&self, cut: u64) -> u64 {
        self.ends[..self.through(cut).len()].last().copied().unwrap_or(0)
    }

    /// The newest settings event through event `cut`.
    pub(crate) fn settings_through(&self, cut: u64) -> Option<&SessionSettings> {
        self.through(cut).iter().rev().find_map(|event| match &event.event {
            SessionEvent::Settings(settings) => Some(settings),
            SessionEvent::Commit(_) => None,
        })
    }

    /// Whether event `seq` is a commit that ends a completed turn.
    pub(crate) fn ends_completed_turn(&self, seq: u64) -> bool {
        let events = self.through(seq);
        events.len() as u64 == seq
            && matches!(
                events.last().map(|event| &event.event),
                Some(SessionEvent::Commit(commit)) if matches!(commit.commit.end, Some(TurnEnd::Completed { .. }))
            )
    }

    /// The event that a fork with no `through` copies through: the end of the newest completed turn. With no completed
    /// turn, the event before the first commit, or the newest event when the log has no commit.
    pub(crate) fn fork_cut(&self) -> u64 {
        let commits = || {
            self.events.iter().filter_map(|event| match &event.event {
                SessionEvent::Commit(commit) => Some((event.event_number.0, commit)),
                SessionEvent::Settings(_) => None,
            })
        };
        commits()
            .filter(|(_, commit)| matches!(commit.commit.end, Some(TurnEnd::Completed { .. })))
            .map(|(seq, _)| seq)
            .next_back()
            .or_else(|| commits().next().map(|(seq, _)| seq - 1))
            .unwrap_or(self.events.len() as u64)
    }
}

/// The model context, the newest turn, and the input tokens of the newest answer of `events`. Each commit applies its
/// replacement, then appends its blocks.
pub(crate) fn replay(events: &[StoredEvent]) -> (Vec<yuke_ai::Block>, NewestTurn, Option<u64>) {
    let mut context: Vec<yuke_ai::Block> = Vec::new();
    let mut newest_turn = NewestTurn::Empty;
    let mut input_tokens = None;
    for event in events {
        let SessionEvent::Commit(commit) = &event.event else {
            continue;
        };
        let commit = &commit.commit;
        if let Some(replaced) = &commit.replaced {
            let kept = context.split_off(context.len().saturating_sub(replaced.keep));
            context = replaced.head.to_vec();
            context.extend(kept);
            input_tokens = None;
        }
        if let Some(answer) = &commit.answer {
            input_tokens = answer.usage.input;
        }
        context.extend(commit.blocks.iter().cloned());
        newest_turn = commit.end.clone().map_or(NewestTurn::Open, NewestTurn::Ended);
    }
    (context, newest_turn, input_tokens)
}

/// The fields of a settings event. The first settings event also holds the system prompt.
#[derive(Serialize)]
#[serde(tag = "kind", rename = "settings")]
struct SettingsBody<'a> {
    #[serde(flatten)]
    settings: &'a SessionSettings,
    #[serde(skip_serializing_if = "Option::is_none")]
    prompt: Option<&'a [PromptSection]>,
}

/// The fields of a commit event, serialized from borrowed parts.
#[derive(Serialize)]
#[serde(tag = "kind", rename = "commit")]
struct CommitBody<'a> {
    commit: &'a Commit<'a>,
    consumed: &'a [ConsumedInput],
}

/// The fields of a settings event, without its number.
pub(crate) fn settings_body(
    settings: &SessionSettings,
    prompt: Option<&[PromptSection]>,
) -> serde_json::Result<Vec<u8>> {
    serde_json::to_vec(&SettingsBody { settings, prompt })
}

/// The fields of a commit event, without its number. The caller serializes the commit once, before it knows the number.
pub(crate) fn commit_body(commit: &Commit<'_>, consumed: &[ConsumedInput]) -> serde_json::Result<Vec<u8>> {
    serde_json::to_vec(&CommitBody { commit, consumed })
}

/// The line of event `seq` with the fields `body`, a JSON object. The `at` field holds the millisecond of the write,
/// so a reader of the file, such as `jq`, sees when each event came. The store does not read it.
pub(crate) fn line(seq: u64, body: &[u8]) -> Vec<u8> {
    // A clock before 1970 writes 0. No ordering depends on this value.
    let at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs() * 1000 + u64::from(since.subsec_millis()));
    let mut line = format!("{{\"seq\":{seq},\"at\":{at},").into_bytes();
    line.extend_from_slice(body.get(1..).unwrap_or_default());
    line.push(b'\n');
    line
}

/// Copy the first `len` bytes of the log in `source` to the log in `folder`, and make them durable.
pub(crate) fn copy_prefix(source: &Path, folder: &Path, len: u64) -> io::Result<()> {
    let mut from = File::open(path(source))?.take(len);
    let mut file = OpenOptions::new().append(true).create(true).open(path(folder))?;
    io::copy(&mut from, &mut file)?;
    file.sync_data()
}

/// Append `bytes` to the log in `folder`. With `durable`, the data reaches the disk before the return.
pub(crate) fn append(folder: &Path, bytes: &[u8], durable: bool) -> io::Result<()> {
    let mut file = OpenOptions::new().append(true).create(true).open(path(folder))?;
    file.write_all(bytes)?;
    if durable {
        file.sync_data()?;
    }
    Ok(())
}

/// The length of the log in `folder`. A missing file has length 0.
pub(crate) fn len(folder: &Path) -> io::Result<u64> {
    match std::fs::metadata(path(folder)) {
        Ok(metadata) => Ok(metadata.len()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(0),
        Err(error) => Err(error),
    }
}

/// Cut the log in `folder` to `len` bytes, and make the cut durable.
pub(crate) fn truncate(folder: &Path, len: u64) -> io::Result<()> {
    let file = OpenOptions::new().write(true).open(path(folder))?;
    file.set_len(len)?;
    file.sync_data()
}
