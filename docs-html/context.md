Edit this file to tune what the agent knows — its contents are appended to the system prompt on
every chat request (live, no restart). Keep it short; it's sent every turn.

- yuke-odin is **pre-release**: backwards compatibility is not required — prefer the cleaner design.
- Build, format, and test commands live in `./build.py` (run `./build.py help` for what exists).
- `src/wire/` is the source of truth for the wire protocol; its tests define accepted vs rejected
  encodings — preserve both the positive behavior and the strict rejection behavior.
- The daemon runs on a single `core:nbio` reactor; the store is SQLite (WAL, synchronous writes on
  the reactor).
- When asked to explain a flow, walk it in the real code and cite `path:line` (and the docs page +
  anchor to open) rather than paraphrasing. You cannot drive the reader's browser.
