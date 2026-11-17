# store

A file store for the sessions of [`yuke-agent`](../agent). `FileStore::open(folder)` keeps one index for all sessions
in `folder/sessions.jsonl`, and a folder for each session in `folder/sessions/<id>/` with the lock file, the event log,
and the blobs of the session. The store uses no database.

## Files

```text
folder/
  store.lock          held for each append to the index
  sessions.jsonl      the index: facts and pending inputs of all sessions
  sessions/<id>/
    lock              the owner lock of the session
    events.jsonl      the event log: one StoredEvent per line
    <sha256>          a blob
```

- The first line of `events.jsonl` is settings event 1. It also holds the system prompt in a `prompt` field, so no
  other file holds the prompt and a fork copies it with the events.
- Each line of `events.jsonl` holds `at`, the millisecond of its write, for a reader of the file such as `jq`. The
  store does not read it, and a fork keeps the times of the copied lines.
- The first line of `sessions.jsonl` holds the tag of the file. Each later line names a session and holds one or more
  changes: `meta` (model, folder, title, parent, fork source, list position, next input id), `add` (a new
  pending input), `remove` (inputs that are no longer pending), or `deleted`. The newest `meta` of a session wins.
- The index stores no time. The creation time comes from the version 7 session id, and the activity time from the
  list position, the microsecond of the newest turn start, turn end, or settings change.
- Only the holder of `store.lock` appends to the index. One thread orders the calls of one process.

## Writes

- A step of a turn appends one line to the log, with no sync. It reads no index.
- A turn start or end, under the store lock: append the line to the log (a turn end syncs it), then append one line
  to the index with the new facts and the consumed inputs. When the index line does not save, the store cuts the log
  line again.
- An accepted input appends one line to the index with the input, its id, and the first title. No sync.
- A new session and a fork take the owner lock of the new folder, write the log durably, and then append the facts to
  the index durably. The sweep at each open removes a folder with no log and a free lock: the rest of a crash during
  a create or a delete.
- A rename appends one line. It changes no event, activity time, or list position.
- A delete appends `deleted`, then removes the log, then the folder.

## Reads

- Each process keeps the folded index in memory. A read opens the index, checks the tag, and reads only the bytes
  after the newest line that it folded. So a list of 1000 sessions reads no session folder.
- The list filters the folded facts by parent and folder, sorts by position, and copies only the facts of the page.
  The position is the microsecond of the newest turn start, turn end, or settings change, and each writer takes a
  position above every position in the index, so two processes never tie.
- `open` reads and replays the log: each commit applies its replacement, then appends its blocks.
- `load` reads the pending inputs from the index, then the log. An input that a log line consumed is not pending.

## Crashes

- A reader stops at the last newline of a log. A new writer cuts the bytes after it. A complete line that is not its
  event fails the read, and no writer cuts it.
- A folder with a log stays, also when the index does not name it. So an index that this yuke cannot read removes no
  session.
- A reader skips an incomplete last line of the index. The next writer cuts it under the store lock, because no other
  writer can be in its append.
- A crash between the log line and the index line of a turn start leaves consumed inputs in the index. `load` hides
  them, and the next writer of the session appends their removal.

## Compaction

When the index is above 1 MiB and above 4 times its live lines, the writer writes the live facts and pending inputs
to a new file with a new tag, syncs it, and renames it over the index. A reader sees the new tag and reads the whole
file again.

## Owner lock

`open` with `Access::Write` locks `sessions/<id>/lock`. A second writer, in this process or another one, gets
`StoreError::Owned`. The lock stays held until the `Lease` drops and each write that the lease started has ended.
`tests/processes.rs` runs a second process on the same folder.

## Blobs

- `put_blob` writes the bytes to `sessions/<id>/<sha256>`. The file is durable before the call returns.
- A second put of the same bytes replaces the file with equal content.
- A blob belongs to one session. The same image in two sessions is two files.
- `read_blob` reads the file synchronously, because the request encoder reads blobs synchronously.

## Session titles

A new session has no title until a text message or an explicit rename supplies one.
The first message with text supplies a title only if the session has none. Later messages do not replace it.
A fork of a titled session starts with `Fork — ` before the source title, limited to 200 Unicode scalar values.
A fork of an unnamed session takes its own first text message as its title.
Titles are display metadata, not model context.
An explicit rename normalizes whitespace and rejects empty titles or titles above 200 Unicode scalar values.

## Fork

- `fork_session` copies the session up to the end of a completed turn: the event that the fork names, or the newest
  completed turn. A copied event keeps its number and its token usage. The newest copied settings
  event gives the settings of the fork. The pending inputs stay with the source.
- The fork locks its new folder, copies each blob file through a temporary file, writes the copied lines, and then
  appends its facts to the index. On a file system with reflinks, such as btrfs or APFS, a copy can share the blocks
  of the source file.
- The fork takes no lock on the source, so a writer of the source can keep its lease during the fork.
- When the copy fails, the store removes the folder of the fork. An error of that removal returns in place of the
  error of the copy.
