# store

A file store for the sessions of [`yuke-agent`](../agent). `FileStore::open(folder)` keeps one index of all sessions
and one folder for each session.

## Files

```text
folder/
  store.lock          held for each append to the index
  sessions.jsonl      the index: facts and pending inputs of all sessions
  sessions/<id>/      <id>: the session id as 32 lowercase hex digits
    lock              the owner lock of the session
    events.jsonl      the event log: one StoredEvent per line
    <sha256>          a blob
```

- The first line of `events.jsonl` is settings event 1. It also holds the system prompt in a `prompt` field, so no
  other file holds the prompt and a fork copies it with the events.
- Each line of `events.jsonl` holds `at`, the Unix time of its write in milliseconds, for a reader of the file such
  as `jq`. The store does not read it, and a fork keeps the times of the copied lines.
- Each line of `sessions.jsonl` names a session and holds one or more changes: `meta` (model, folder, title,
  parent, fork source, list position), `add` (a new pending input), `remove` (inputs that are no longer pending), or
  `deleted`. The newest `meta` of a session wins. The next input id is one above the highest id that an `add` holds,
  so ids never repeat in a session.
- The index stores no time. The creation time comes from the version 7 session id, and the activity time from the
  list position.
- Only the holder of `store.lock` appends to the index. One thread orders the calls of one process, because a file
  lock does not keep apart two threads that share its file.

## Writes

- A step of a turn appends one line to the log. It does not sync the log, and it reads no index.
- A turn start or a turn end takes the store lock. It appends its line to the log, and a turn end syncs the log. Then
  it appends one line to the index with the new facts and the consumed inputs. When the index line does not save, the
  store removes the log line.
- An accepted input appends one line to the index with the input, its id, and the first title. It does not sync the
  index.
- A new session and a fork take the owner lock of the new folder, write the log durably, and then append the facts to
  the index durably.
- A rename appends one line. It changes no event, activity time, or list position.
- A delete appends `deleted`, then removes the log, then the folder.

## Reads

- Each process keeps the folded index in memory. Its first read folds the whole index. A later read reads only the
  lines after the newest line that it folded. So a list reads no session folder.
- The list orders the sessions by position: the microsecond of the newest turn start, turn end, or settings change.
  Each writer takes a position above every position in the index, so two processes never tie.
- `load` reads the pending inputs from the index, then the log. An input that the newest event consumed is not
  pending.

## Crashes

- A reader stops at the last newline of a log. A new writer cuts the bytes after it. A complete line that does not
  parse, or that has the wrong event number, fails the read, and no writer cuts it.
- Each open removes the folders that a crash during a create or a delete leaves: a folder that the index does not
  name, with no log and a free lock. A folder with a log stays, also when the index does not name it. So an index
  that this yuke cannot read removes no session.
- A reader skips an incomplete last line of the index. The next writer cuts it under the store lock, because no other
  writer can be in its append.
- A crash between the log line and the index line of a turn start leaves consumed inputs in the index. `load` hides
  them, and the next writer of the session appends their removal.

## Growth

The index only grows. A turn adds about 700 bytes and the full text of its input. The first read of a process folds
about 500 MB per second, so a year of heavy use, about 25 to 40 MB, adds about 50 to 80 ms.

## Owner lock

`open` with `Access::Write` locks `sessions/<id>/lock`. A second writer, in this process or another one, gets
`StoreError::Owned`. The lock stays held until the `Lease` drops and each write that the lease started has ended.

## Blobs

- `put_blob` writes the bytes to `sessions/<id>/<sha256>`. The file is durable before the call returns.
- A second put of the same bytes replaces the file with equal content.
- A blob belongs to one session. The same image in two sessions is two files.
- `read_blob` reads the file synchronously, because the request encoder reads blobs synchronously.

## Fork

- `fork_session` copies the session up to the end of a completed turn: the event that the fork names, or the newest
  completed turn. A copied event keeps its number and its token usage. The newest copied settings event gives the
  settings of the fork. The pending inputs stay with the source.
- The fork locks its new folder, copies each blob file through a temporary file, writes the copied lines, and then
  appends its facts to the index. On a file system with reflinks, such as btrfs or APFS, a copy can share the blocks
  of the source file.
- The fork takes no lock on the source, so a writer of the source can keep its lease during the fork.
- When the copy fails, the store removes the folder of the fork and returns the error of the copy.
