//! The session index: `sessions.jsonl` beside the session folders. Each line changes the facts or the pending inputs
//! of one session. Only the holder of the store lock appends, so the newest line of a session wins. A reader keeps the
//! folded lines in memory and reads only the lines after its offset, so a list costs one open and one read of the new
//! lines. The file only grows: a turn adds about 1.5 KB, and a fold of 50 MB takes about 0.1 s.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{self, BufRead, BufReader, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use yuke_protocol::{Input, InputId, ModelReference, PendingInput, SessionId};

/// The name of the index file in the store folder.
pub(crate) const INDEX: &str = "sessions.jsonl";

/// The facts of a session that the list and the summary read.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct Meta {
    /// The model of the newest settings event.
    pub(crate) model: ModelReference,
    /// The folder of the newest settings event.
    pub(crate) cwd: PathBuf,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) fork_of: Option<SessionId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) parent: Option<SessionId>,
    /// The list position: the microsecond of the newest turn start, turn end, or settings change. It orders the list
    /// and gives the activity time.
    pub(crate) position: u64,
    /// The id of the next accepted input. Ids start at 1 and never repeat in a session.
    pub(crate) next_input: u64,
}

/// One line of the index.
#[derive(Debug, Serialize, Deserialize)]
pub(crate) struct Line {
    pub(crate) id: SessionId,
    /// The new facts of the session. A line with facts makes the session when it does not exist.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) meta: Option<Meta>,
    /// A new pending input.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) add: Option<Added>,
    /// Pending inputs that are no longer pending.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) remove: Vec<InputId>,
    /// The session is gone.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub(crate) deleted: bool,
}

impl Line {
    /// A line that sets the facts of session `id`.
    pub(crate) fn meta(id: SessionId, meta: Meta) -> Line {
        Line {
            id,
            meta: Some(meta),
            add: None,
            remove: Vec::new(),
            deleted: false,
        }
    }

    /// A line that removes pending inputs from session `id`.
    pub(crate) fn remove(id: SessionId, remove: Vec<InputId>) -> Line {
        Line {
            remove,
            ..Line::bare(id)
        }
    }

    /// A line that deletes session `id`.
    pub(crate) fn deleted(id: SessionId) -> Line {
        Line {
            deleted: true,
            ..Line::bare(id)
        }
    }

    fn bare(id: SessionId) -> Line {
        Line {
            id,
            meta: None,
            add: None,
            remove: Vec::new(),
            deleted: false,
        }
    }
}

/// A pending input in a line.
#[derive(Debug, Serialize, Deserialize)]
pub(crate) struct Added {
    pub(crate) id: InputId,
    pub(crate) input: Input,
}

/// One session in the index.
#[derive(Debug)]
pub(crate) struct Entry {
    pub(crate) meta: Meta,
    pub(crate) pending: Vec<PendingInput>,
}

/// The folded index of one process.
#[derive(Debug)]
pub(crate) struct Index {
    path: PathBuf,
    /// The end of the newest complete line that this process folded.
    offset: u64,
    sessions: HashMap<SessionId, Entry>,
    /// The largest list position that this process read or wrote. A new position comes above it, so the positions of
    /// two processes never tie.
    newest_position: u64,
}

impl Index {
    /// An index of the store folder `folder` that read no line.
    pub(crate) fn new(folder: &Path) -> Index {
        Index {
            path: folder.join(INDEX),
            offset: 0,
            sessions: HashMap::new(),
            newest_position: 0,
        }
    }

    /// The sessions after the last [`Index::refresh`].
    pub(crate) fn sessions(&self) -> &HashMap<SessionId, Entry> {
        &self.sessions
    }

    /// The next list position, above each position that this process read or wrote.
    pub(crate) fn next_position(&self) -> u64 {
        next_tick(self.newest_position)
    }

    /// Session `id` after the last [`Index::refresh`].
    pub(crate) fn get(&self, id: SessionId) -> Option<&Entry> {
        self.sessions.get(&id)
    }

    /// Fold the lines that other processes appended since the last call. An incomplete last line stays unread: a writer
    /// can be in its append, or a crash left it.
    pub(crate) fn refresh(&mut self) -> io::Result<()> {
        let file = match File::open(&self.path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                self.reset();
                return Ok(());
            }
            Err(error) => return Err(error),
        };
        let len = file.metadata()?.len();
        if len < self.offset {
            // The file is shorter than the lines that this process folded, so it is a new file.
            self.reset();
        }
        if len == self.offset {
            return Ok(());
        }
        let mut reader = BufReader::with_capacity(1 << 16, file);
        reader.seek(SeekFrom::Start(self.offset))?;
        let mut line = Vec::new();
        loop {
            line.clear();
            let read = reader.read_until(b'\n', &mut line)?;
            if line.pop() != Some(b'\n') {
                return Ok(());
            }
            self.offset += read as u64;
            // A line that does not parse came from a newer yuke or a damaged disk. The other lines still count.
            if let Ok(parsed) = serde_json::from_slice::<Line>(&line) {
                self.apply(parsed);
            }
        }
    }

    fn reset(&mut self) {
        self.offset = 0;
        self.sessions.clear();
    }

    fn apply(&mut self, line: Line) {
        if let Some(meta) = &line.meta {
            self.newest_position = self.newest_position.max(meta.position);
        }
        if line.deleted {
            self.sessions.remove(&line.id);
            return;
        }
        let entry = match (self.sessions.get_mut(&line.id), line.meta) {
            (Some(entry), Some(meta)) => {
                entry.meta = meta;
                entry
            }
            (Some(entry), None) => entry,
            (None, Some(meta)) => self.sessions.entry(line.id).or_insert(Entry {
                meta,
                pending: Vec::new(),
            }),
            // A line of a deleted session.
            (None, None) => return,
        };
        if let Some(Added { id, input }) = line.add {
            entry.pending.push(PendingInput { id, input });
        }
        if !line.remove.is_empty() {
            entry.pending.retain(|input| !line.remove.contains(&input.id));
        }
    }

    /// Append `line` and fold it. The caller holds the store lock and called [`Index::refresh`] under it. With
    /// `durable`, the line reaches the disk before the return.
    pub(crate) fn append(&mut self, line: Line, durable: bool) -> io::Result<()> {
        let mut bytes = serde_json::to_vec(&line)?;
        bytes.push(b'\n');
        let mut file = OpenOptions::new().append(true).create(true).open(&self.path)?;
        if file.metadata()?.len() > self.offset {
            // Under the store lock no writer is in its append, so these bytes are the torn line of a crash.
            file.set_len(self.offset)?;
        }
        file.write_all(&bytes)?;
        if durable {
            file.sync_data()?;
        }
        drop(file);
        self.apply(line);
        self.offset += bytes.len() as u64;
        Ok(())
    }
}

/// The newest value that [`next_tick`] gave in this process.
static LAST_TICK: AtomicU64 = AtomicU64::new(0);

/// The current time in microseconds, and at least one above the value before it in this process and `floor`.
fn next_tick(floor: u64) -> u64 {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |time| u64::try_from(time.as_micros()).unwrap_or(u64::MAX));
    let mut last = LAST_TICK.load(Ordering::Relaxed);
    loop {
        let next = now.max(last + 1).max(floor + 1);
        match LAST_TICK.compare_exchange(last, next, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return next,
            Err(seen) => last = seen,
        }
    }
}
