# Prompt: plan yuke image support (engine first)

You are reviewing this brief and writing an implementation plan. Do not implement yet. The product is pre-release: breaking changes are welcome when they make the code simpler, faster, or easier to review and test. Protocol changes must still be deliberate and coordinated, never accidental drift. `lib/proto/` is authoritative. `schema/proto.json` and `src/js/app/generated/proto.d.ts` are generated (`zig build gen-schema`). Tests define accepted and rejected encodings.

This brief is the result of a codebase read plus a comparison of how fx, Pi, Grok TUI, and Codex TUI send images. The conclusion: **no yuke client can send images today, and client work cannot close the loop until the engine stores and resolves blob bytes.**

---

## 1. Task

Write a PR plan for the **first vertical slice** of user-sent images:

> A client calls `blob.put { path }`. The engine reads the file, sniffs the type, hashes it, and copies it into an engine-owned content-addressed store. `session.send_input` / `session.create` may then carry `ContentPart.image` blob refs. A vision model receives real image blocks. A text-only model receives the existing omission note. A missing or mismatched ref is refused at admission, not at request build. `session.remove` unlinks blobs that no other session references.

The plan must say what is in v1, what is explicitly later, and which protocol changes need a user decision before coding.

Do **not** plan the TUI paste UI, the GUI drop target, Kitty graphics, `/image`, or clipboard as part of v1 except as a one-line follow-on that becomes possible after this slice.

---

## 2. Clients and transports (why the put is an RPC method)

yuke has two clients and both must be able to attach an image:

- **TUI** (`src/js/app/`), in-process QuickJS. It calls the engine through `native.request(method, JSON.stringify(params))` (`src/js/native/engine.zig` `jsRequest`). Every request is one JSON string.
- **GUI** (`xyaman/yuke-guix`, TypeScript over gpuix). `src/engine.ts` spawns `yuke --rpc` and speaks JSONL over stdio pipes. `src/protocol/wire.d.ts` is a pinned copy of the generated `Wire` declarations; `bun run protocol:check` fails when the engine protocol drifts. Its line splitter caps a line from the engine at 2 MiB.

The engine stdin buffer is `max_message_string_bytes + 64 KiB` (1 MiB + 64 KiB, `src/app/rpc.zig` `in_buffer_bytes`). A longer line is a fatal `StreamTooLong`. **Base64 bytes on JSONL are therefore out.** A 20 MiB PNG is a 27 MiB line.

The only shape that serves both clients with one code path is a method that names a **file path**. The engine reads the file itself. Bytes never cross JSONL, QuickJS, or the event log. The TUI and the GUI both run on the machine that owns the file, and the GUI spawns the engine as the same user, so this is the same trust domain as the tools that already read any absolute path (`paths.anchorAt` has no confinement).

A native ArrayBuffer put for the TUI is **not** in this plan. One method, one test surface.

---

## 3. What already exists (do not reinvent)

### Wire: content-addressed ref, not pixels

`lib/proto/content.zig`:

**Step 1 of section 11 is done (uncommitted).** The wire now reads:

- `MediaBlob = { hash: ids.BlobHash, mime, bytes }` — `bytes` is **size**, not payload. `ids.BlobHash = HexId(32)`: 32 raw bytes, 64 lowercase hex on the wire, and the parser rejects anything else (`LengthMismatch`, `InvalidCharacter`, `UnexpectedToken`). A hash that reached Zig is safe in a path by construction.
- `ContentPart = text | image | audio | file`. Each media part has `source: MediaBlob`. The one-arm `MediaSource` union and `ContentImage.detail` are gone.
- `lib/proto/blob.zig` holds `BlobPutParams { path }`. `MethodName.@"blob.put"` returns `MediaBlob`. `protocol_version` is 2. Schema and `proto.d.ts` are regenerated.
- `blob.put` has **no binding yet** in `call.zig`, so the engine answers it as an unsupported method until step 5.

```json
{"type":"image","source":{"hash":"<64 hex chars>","mime":"image/png","bytes":1024}}
```

### Persistence already accepts image parts

- `session.send_input` (`src/engine/commands.zig` `sessionSendInputForRpc`) takes `params.input.content` with no part-kind filter.
- `session.create` `initial_input` (`lib/proto/misc.zig` `CreateSession`) is the same `Input` union. The GUI creates a session from a draft with `initial_input`, so a put happens **before the session exists**.
- `src/engine/run.zig` `beginTurn` / `consumeQueued` copies `input.content` onto the user message as-is.
- `src/store/message.zig` `appendCommittedMessage` JSON-stringifies the whole `proto.message.Message` into `events.payload` (TEXT).
- `src/store/input.zig` `enqueue` JSON-stringifies `QueuedInput` into `pending_inputs.payload`.

So a blob **ref** can already live in the log. The pixels cannot.

### Session removal exists; fork and rewind do not

- `session.remove` is bound (`src/app/call.zig` `bindings`, `commands.sessionRemove`). It refuses a busy or pinned session, collects the cascade set, and deletes the session rows in one transaction (`session.sql` `DeleteSession`, child tables cascade). It knows nothing about blobs.
- `session.fork` and `session.rewind` are in `MethodName` and `rpc.methods` but have **no binding** in `call.zig`. They are unimplemented. The plan must not describe fork copy semantics as existing behavior.

### Provider stack already serializes images

- IR: `lib/ai/request/ir.zig` `Block.Value.media` with `mime` + `types.MediaSource = bytes | url | file_id`. `ir.modalityOf(mime)` maps `image/*` to `.image`.
- Comment on `types.MediaSource`: *"A caller resolves its own storage before it serializes."* (`lib/ai/types.zig`)
- `max_media_bytes = 32 << 20` in `lib/ai/types.zig` `limits`.
- Anthropic: `lib/ai/request/anthropic.zig` `writeMedia` — base64-encodes `.bytes` at write time into `{type:"image", source:{type:"base64", media_type, data}}`.
- OpenAI Chat: `image_url` data URL (`lib/ai/request/openai_chat.zig`). OpenAI Responses: `input_image` (`openai_responses.zig`).
- Catalog: `supports_vision` / `modalities.input` including `.image`. `Modalities.takesInput(kind)` returns `null` for an empty list.
- `src/engine/request.zig` `prepare` calls `request_builder.build(arena, messages, .{ .modalities = model.modalities })`.

### Omission for text-only models already works

`src/provider/request_builder.zig` `mediaValue`:

- If the model lists input modalities and does **not** take this kind → static note, e.g. `"[image omitted: this model reads no images]"`.
- If it takes the kind, **or lists nothing** → `error.UnresolvedBlob` (bytes are owed).
- Tests in the same file: `"a model that reads no images sees a note where the attachment was"` and `"the media type selects the omitted-attachment note"`. They use `.hash = .bytes(@splat(0))` and must keep passing without a store.

### Compaction already names attachments

`src/engine/compaction.zig` `renderMessage`: user `.image | .audio | .file` → `"[User]: (an attachment)\n\n"`. Fine for v1.

### SHA-256 and file reads already exist

- `std.crypto.hash.sha2.Sha256.hash` in `src/engine/agent_config.zig`, `src/session/instructions.zig`.
- `src/session/skills.zig` `readBody` / `readText` reads a bounded file through `std.Io` and reports through a `diagnostic` string. Copy that pattern for the put.

### Engine test fixture

`src/engine/test_resources.zig` holds a `CannedTransport` and `makeEngine`. The integration test extends that fixture.

### Extension hook

`input.before` (`lib/proto/hook.zig`, folded in `src/js/app/ext.js` `prepareInput`) sees `content` parts and may `replace` them **before** native admission. A plugin can inject an image part with any hash. Engine admission is the source of truth.

---

## 4. The hole

```zig
// src/provider/request_builder.zig mediaValue
// The model reads this kind, so the bytes must arrive. No blob store exists to read them yet.
return error.UnresolvedBlob;
```

`request_builder.build` is a pure function of messages with **no store argument**. `Engine.Deps` (`src/engine/Engine.zig`) has `db`, providers, transport, execution, tools, hooks — **no blob store** and no blob directory.

If you sent an image ref today:

1. Input is committed (user message in the log).
2. Run starts.
3. `prepare` → `build` → `UnresolvedBlob`.
4. `src/engine/turn.zig` `streamRound` maps via `provider.failure.classify`.
5. `UnresolvedBlob` is **not** in `src/provider/failure.zig` `classify`, so it becomes a generic **provider** failure.
6. Transcript keeps a dangling ref.

`src/app/call.zig` `failureFor` has no blob errors. Every put and admit failure lands there as `bad_request`.

---

## 5. v1 shape

### 5.1 Store: files named by hash, refs in SQLite

- Location: `<data>/blobs/<64hex>` beside `yuke.db` (`src/paths.zig` `dataDir`, opened in `src/app/app.zig`). Tests use a temp dir.
- Key: the 32-byte SHA-256 of the raw bytes. The filename is `std.fmt.bytesToHex(hash.raw, .lower)`. The parser already refused every non-hex wire value, so no path check exists at admission.
- Value: the raw bytes only. No sidecar. The mime is re-derived from magic bytes when needed.
- Put is idempotent: same hash twice is success. Write to a temp name in the same directory, then rename, so a crash never leaves a partial file under a valid hash.
- New table via migration `0005_blob_refs.sql` (`src/store/store.zig` `migrations`, next version is 5):

```sql
CREATE TABLE blob_refs (
  session_id BLOB NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  hash TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  PRIMARY KEY (session_id, hash)
);
CREATE INDEX blob_refs_hash ON blob_refs(hash);
```

  Admission inserts one row per image part in the same transaction as the commit or enqueue. `bytes` is stored so a later context-budget pass can charge it without opening files.

- **Removal:** `sessionRemove` collects the hashes of the doomed sessions before the delete, deletes the rows (or lets the cascade do it), commits, then unlinks every hash with zero remaining rows. Unlink after commit: a crash between the two leaves an orphan file, never a dangling ref. Orphans are harmless and a later sweep may collect them.
- **Fork / rewind:** unimplemented today. When fork lands it copies the parent rows. Rewind may leave stale rows; a stale row only delays cleanup until remove.

Do **not** put image bytes in `events.payload`. Do **not** put bytes in SQLite.

### 5.2 Put: `blob.put { path }` → `MediaBlob`

New protocol method. Wire the full set: `MethodName.@"blob.put"`, `rpc.methods` row, `RequestParams` / `ResponseResult` arms, `registry.zig` entries, `call.zig` binding, `client.js` wrapper, `zig build gen-schema`, `zig fmt`. The GUI re-pins `wire.d.ts` after.

```zig
pub const BlobPutParams = struct { path: []const u8 };
// result: content.MediaBlob
```

Checks at put (operating errors, never asserts, each a distinct message through `diagnostic`):

- `path` must be absolute. Use the same rule as the other host FS ops. Expand `~` through `paths.anchorAt` only if the plan wants it; say so.
- Open and stat. Empty file refuses. Size over the cap refuses **before** the read.
- Read the first 16 bytes and sniff: PNG `89 50 4E 47 0D 0A 1A 0A`, JPEG `FF D8 FF`, GIF `GIF87a` / `GIF89a`, WebP `RIFF....WEBP`. Anything else refuses. The client never declares a mime. The sniffed mime is the mime of the ref.
- Read the rest, SHA-256 into `BlobHash.bytes(digest)`. `bytes = size`.
- If `<data>/blobs/<hash>` exists, return without writing. Else temp + rename.

Cap: **7 MiB raw** for v1. Verified provider limits (2026-09-11):

| Provider | Per image | Per request | Images per request | Formats |
| --- | --- | --- | --- | --- |
| Anthropic API (`platform.claude.com/docs/en/build-with-claude/vision`) | 10 MB **base64-encoded** (5 MB on Bedrock / Vertex) | 32 MB | 100 (200k models) / 600; over 20 images per request every image must fit 2000 px | png, jpeg, gif, webp; animated gif uses the first frame; 8000×8000 px max |
| OpenAI (`developers.openai.com/api/docs/guides/images-vision`) | none stated | 512 MB | 1500 | png, jpeg, webp, non-animated gif |

7 MiB raw is 9.33 MiB base64, under the Anthropic 10 MB limit, so one cap at put is correct for every provider and no per-provider check is needed at build. A larger cap would need the Anthropic serializer to refuse before send, which is a second limit to test; do not add it in v1. 7 MiB loses nothing in practice: every model downscales to at most 2576 px on the long edge, and a screenshot at that size is well under 2 MiB. The round arena holds the raw bytes plus the base64 body (about 2.3× per image per round), so `ai.types.limits.max_media_bytes` (32 MiB) is not the cap to reuse.

Skip a `mime` param, an ArrayBuffer variant, and a base64 variant. Clipboard images become a temp file on the client (Pi and Codex do this). A remote daemon transport would need a different put; that transport does not exist.

### 5.3 Admit refs on input

Before enqueue / `beginTurn`, walk `content` parts. For each `.image` blob:

- `<data>/blobs/<hash>` exists and its size equals `bytes` → else `bad_request`.
- the first 16 bytes sniff to the declared `mime` → else `bad_request`. This is one small read per part and replaces a sidecar.
- at most **8** image parts per input → else `bad_request`. `max_input_parts` (256, `lib/proto/meta.zig`) stays unenforced; name that.
- `.audio` and `.file` parts → `bad_request` in v1. The wire arms stay; the engine refuses them until a later slice.

Same walk on `session.create` `initial_input`. Skill inputs stay text. Insert `blob_refs` rows in the same transaction as the commit or enqueue. Nothing is committed on refusal.

Empty text plus one image is a valid user message. `request_builder` already skips empty user text.

### 5.4 Resolve at request build

Add a lookup to `request_builder.Options`:

```zig
pub const Options = struct {
    target: ?types.ModelIdentity = null,
    modalities: types.Modalities = .{},
    blobs: ?BlobLookup = null,
};
```

`BlobLookup` is a small vtable or function pointer with one `get(hash) ?[]const u8`. `request_builder` must not import the store or the database. Tests inject a map.

`mediaValue` order stays: stated refusal → note, no lookup. Otherwise `blobs.get(hash)` → `ir.Block.Value.media{ .source = .{ .bytes = data }, .mime = blob.mime }`. `null` lookup or missing hash → `UnresolvedBlob`.

`prepare` (`src/engine/request.zig`) builds the lookup over the blob directory and reads each file into the round arena. Anthropic base64-encodes at write time, so the raw bytes must outlive serialization; the arena already does.

After admission, a missing file at build time is a corrupt store. Map `UnresolvedBlob` to `RunErrorCode.runtime` in `src/provider/failure.zig` with a message that names the hash. Not `provider`.

Do not resolve inside the serializer.

### 5.5 Tests that must exist in v1

Positive:

- `blob.put` on a 1×1 PNG → `MediaBlob` with the expected hash, `image/png`, size. File exists under that name.
- put twice → same hash, no second write (mtime or a counter).
- put JPEG, GIF, WebP → their mimes.
- `session.send_input` with that ref plus text → user message committed with the ref only (assert `events.payload` holds no base64), one `blob_refs` row.
- `session.create` with `initial_input` carrying a ref → same.
- `request_builder.build` with vision modalities and a map lookup → one `media` block whose bytes equal the put.
- Anthropic serializer: the body contains a base64 image block for those bytes (`"an image and a document reach their own block shapes"` shows the shape). One OpenAI serializer too.
- `session.remove` → the file is gone. Two sessions share a hash, remove one → the file stays.
- Engine-level: put → send → a turn against `CannedTransport` produces a request body with an image block.

Negative (strict):

- put on a PDF, a text file, an empty file, a file one byte over 7 MiB, a relative path, a missing path → `bad_request` with distinct messages. No file written.
- put on a `.png` whose bytes are not PNG → refused.
- send_input with a random hex hash → `bad_request`, no `message.committed`, no `blob_refs` row.
- send_input with a hash that is 64 non-hex bytes (including `/`) → `bad_request` from the parser (`content.zig` already tests the parse; the RPC test asserts the wire code).
- send_input with the right hash but wrong `bytes` or wrong `mime` → `bad_request`.
- nine image parts → `bad_request`.
- an `.audio` or `.file` part → `bad_request`.
- text-only modalities → omission note, lookup never called (keep the existing test).
- empty modalities list plus a resolvable blob → bytes owed, media block. Empty list plus a missing blob → `UnresolvedBlob`.
- `failure.classify(error.UnresolvedBlob)` → `.runtime`.

---

## 6. Protocol decisions (plan must settle these)

| Topic | Default in this brief | Why |
| --- | --- | --- |
| New RPC `blob.put { path }` → `MediaBlob` | **Done on the wire**, binding pending | The GUI is out of process; JSONL cannot carry bytes; one path for both clients |
| `MediaSource` | **Done**: flattened to `source: MediaBlob` | `blob.put` is the only way a ref is born; a one-arm closed union was a speculative layer |
| `ContentImage.detail` | **Done**: dropped | No serializer maps it |
| `ContentAudio` / `ContentFile` | **Keep** the arms, engine refuses them | The shape is right; put and sniff for them are a later slice |
| New `ErrorCode` | **No**; `bad_request` with distinct messages | Prefer existing codes |
| `RunErrorCode` for unresolved blob at prepare | **Map to `runtime`** in `failure.zig` | Today it is a generic provider failure |
| Image cap | **7 MiB raw** at put | 9.33 MiB base64 fits the verified Anthropic 10 MB per-image limit; one cap for every provider |
| Image mime set | png/jpeg/gif/webp by magic bytes | Client never declares a mime |
| Hash | **Done**: `ids.BlobHash = HexId(32)`, hex-validated at parse | Same type family as `SessionId`; the filename is the hex form |
| SQLite | **Migration 0005 `blob_refs`** | The only cheap way `session.remove` can unlink |
| `protocol_version` (`lib/proto/initialize.zig`) | **Done**: 2 | The GUI pins it |

---

## 7. Code map (read these)

| Area | Path |
| --- | --- |
| Wire types | `lib/proto/content.zig`, `lib/proto/input.zig`, `lib/proto/misc.zig` (`CreateSession`), `lib/proto/rpc.zig` `methods` / `RequestParams` / `ResponseResult`, `lib/proto/enums.zig` `MethodName` / `ErrorCode` / `RunErrorCode`, `lib/proto/meta.zig` limits, `lib/proto/registry.zig`, `lib/proto/initialize.zig` `protocol_version` |
| RPC binding | `src/app/call.zig` `bindings` / `failureFor`, `src/app/rpc.zig` `in_buffer_bytes` |
| Send / create / remove | `src/engine/commands.zig` `sessionSendInputForRpc`, `sessionCreateForRpc`, `sessionRemove`, `removalSet` |
| Commit | `src/engine/run.zig` `beginTurn`, `consumeQueued` |
| Log | `src/store/message.zig`, `src/store/input.zig`, `src/store/session.zig` `remove`, `src/store/queries/session.sql` `DeleteSession`, `src/store/store.zig` `migrations`, `src/store/migrations/` |
| Build request | `src/engine/request.zig` `prepare`, `src/provider/request_builder.zig` |
| Failures | `src/provider/failure.zig`, `src/engine/turn.zig` `streamRound` |
| Context budget | `src/engine/context.zig`; `src/store/queries/message.sql` `ContextSizes` uses `length(CAST(e.payload AS BLOB))` — **JSON ref size, not `MediaBlob.bytes`** |
| Compaction | `src/engine/compaction.zig` `renderMessage` |
| Engine deps | `src/engine/Engine.zig` `Deps` |
| Data dir | `src/paths.zig` `dataDir` / `anchorAt`, `src/app/app.zig` open |
| Bounded file read pattern | `src/session/skills.zig` `readBody` |
| Engine fixture | `src/engine/test_resources.zig` `CannedTransport`, `makeEngine` |
| JS client | `src/js/app/client.js` (add `blobPut`), `src/js/app/chat.js` `textInput`, `src/js/app/ext.js` `prepareInput` |
| IR / serializers | `lib/ai/request/ir.zig`, `lib/ai/types.zig`, `lib/ai/request/anthropic.zig`, `openai_chat.zig`, `openai_responses.zig` |
| Schema gen | `tools/protogen`, `zig build gen-schema`, `zig build check-schema` |
| GUI pin | `../yuke-guix/src/protocol/wire.d.ts`, `pin.json`, `bun run protocol:check` |

---

## 8. Blockers and traps

1. **Bytes on the wire.** JSONL is capped at about 1 MiB per line and QuickJS params are one JSON string. Never inline bytes or base64. The path method is the whole point.
2. **Commit-then-fail.** Admission runs **before** `beginTurn` / `enqueue`. Otherwise the user message is durable and the run dies with a dangling ref.
3. **Hash is a filename.** `BlobHash` parses only 64 lowercase hex, so a decoded hash is path-safe. Build the name with `bytesToHex`; never accept a client string as a name.
4. **`request_builder` has no store.** A disk directory without the lookup in `build` changes nothing.
5. **UnresolvedBlob → generic provider.** Map it. Tests assert the wire code.
6. **Text-only vs empty modalities.** Empty `modalities.input` means "stated no refusal", so bytes are still owed. Do not treat empty as text-only.
7. **Context estimate undercount.** `ContextSizes` measures JSON payload length. A 5 MiB PNG costs about 200 bytes in the estimate. `blob_refs.bytes` exists so a follow-on can charge it. Name the follow-on; do not pretend the estimate is right.
8. **`input.before` replace.** A plugin can inject any hash after the client put. Admission decides.
9. **Put before create.** The GUI puts while still a draft. The store is global, not per session, so this works. `blob_refs` rows appear at admission, not at put. A put with no later send leaves an orphan file; a later sweep may collect it.
10. **Unlink ordering on remove.** Delete rows, commit, then unlink. Never unlink first.
11. **Shared hash across sessions.** Remove unlinks only when the hash count is zero. Test it.
12. **Round arena cost.** Raw bytes plus base64 per image per round. Measure one turn with a 7 MiB image under `-Dmetrics=true` and report peak bytes.
16. **Images accumulate across turns.** Every turn resends the whole transcript. Anthropic counts every image block in the request, including earlier turns, and applies a 2000 px per-image limit once a request holds more than 20. Eight per input keeps one turn safe; a long session can still cross 20. Name it as a follow-on (downscale at put, or the Files API `file_id` source that `ir` already models).
13. **Zero-hash tests.** The `request_builder` omission tests use `.hash = .bytes(@splat(0))`. They must keep passing with `blobs = null`.
14. **Fork and rewind are unimplemented.** Do not write their blob behavior as code; write it as a one-line note for when they land.
15. **GUI pin.** `protocol:check` in the GUI fails after this change until it re-pins. Say so in the PR.

---

## 9. Optimizations and simplifications (prefer these)

- **One put for every client.** `blob.put { path }` over the normal request path. No native ArrayBuffer function, no mime param, no base64 variant.
- **Engine is the oracle.** It sniffs, hashes, sizes. The client echoes the returned `MediaBlob` into the part.
- **No sidecar.** Admission re-sniffs 16 bytes and stats. Mime and size live in the ref and are verified against the file.
- **One sniff table in one place** used by put and admit.
- **`blob_refs` is the whole GC.** Insert at admission, count on remove. No refcount column, no background job.
- **Lookup interface, not a god object.** `request_builder` gets `get(hash) ?[]const u8`. Tests inject a map.
- **Keep omission notes as static strings.**
- **Temp + rename** for the file write. No fsync ceremony beyond what the DB already does.
- **Do not implement** Kitty preview, composer chips, `/paste`, `@` image picking, a GUI drop target, or a blob read method in this slice.
- **Do not teach `read` to return images.** Agent-initiated vision is a different feature (`src/js/native/engine/project.zig`: *"An image view names a blob; it carries no inline bytes."*).

---

## 10. Peer implementations (for the client follow-ons, not v1)

Copy the **ingest pattern**, not the protocol:

| Agent | User send path |
| --- | --- |
| **fx** | `/image path`, type path, `@` picker, `/paste` clipboard (macOS), `fx ask --image`. PNG/JPEG/GIF/WebP, 20 MiB. Vision fallback model if the main model is blind. |
| **Pi** | `app.clipboard.pasteImage`: Ctrl+V (Alt+V on Windows/WSL). Core writes a temp path; extensions attach ImageContent. |
| **Grok TUI** | Cmd+V / Ctrl+V / Alt+V OS clipboard. `grok wrap` OSC host-clipboard inject, 20 MiB, JPEG recompress. |
| **Codex** | Ctrl+V via `arboard`, Alt+V on Windows, WSL PowerShell fallback; drag/paste image **paths**; `codex -i file.png`. |

Common pattern: **OS clipboard API, then a temp file, then a path.** Kitty, Ghostty, and WezTerm will not inject PNG through bracketed paste. `blob.put { path }` is exactly the half every peer ends in.

---

## 11. Suggested plan shape (for you to refine)

Ordered, each step independently testable:

1. **Done.** Proto: `blob.put` method, `BlobPutParams`, `BlobHash`, flattened `MediaSource`, dropped `detail`, `protocol_version` 2, schema regenerated.
2. **Done.** `src/store/blob.zig`: `Store { dir }` with `put` (stat, cap, sniff, SHA-256, temp + rename), `admit` (exists, size, 12-byte re-sniff, 8-image cap, audio/file refused), `read`, `unlink`; tests on a temp dir.
3. **Done.** Migration `0005_blob_refs.sql` and `queries/blob.sql`: `recordRefs` at the two log writers (`appendCommittedMessage` for user messages, `enqueue`), `refsOf`, `referenced`.
4. **Done.** `Engine.Deps.blobs`, `App.blob_dir` (`paths.blobDirIn`), `App.initTest` takes a dir, `test_resources` gives every engine fixture a temp blob dir.
5. **Done.** `call.zig` binds `blob.put`; every put and admit error maps to `bad_request` with its own message; `client.js` `blobPut`.
6. **Done.** `admit` runs in `sessionSendInputForRpc` and `sessionCreateForRpc` before any durable write.
7. **Done.** `sessionRemove` reads the doomed refs, deletes in one tx, commits, then unlinks every hash no session names.
8. **Done.** `request_builder.Options.blobs: ?BlobLookup`; `prepare` supplies a `BlobReader` over the round arena; `UnresolvedBlob` classifies as `runtime`.
9. **Done.** `src/engine/blob_test.zig`: vision body carries the base64 bytes and the log carries only the ref; text-only model gets the note with the file deleted; bad refs never commit on send or create; the last removal unlinks and a shared blob survives the first. Eight production mutations each fail at least one test.
10. **Arithmetic, not a harness number.** The request arena is per round (`turn.zig streamRound` creates `round_state` and frees it at the end of the round). Per round each image costs its raw size in the arena plus 4/3 of it in the request body, so 8 images at 7 MiB cost 56 MiB + 75 MiB for that round and nothing after it. The `-Dmetrics=true` bench covers the JS host and renderer allocator only, so this path has no counter; that is a stated gap.
11. `zig fmt`, `zig build test`, `zig build test-js`, `zig build check-schema`.

Explicitly out of v1 (list in the plan so they are not smuggled):

- TUI clipboard / chips / `@image` / Kitty draw; GUI drop target and paste
- `blob.path { hash }` or any blob read method (the GUI needs it to render the image; same trust domain, returns a path)
- Context-budget charging of `blob_refs.bytes` (visual tokens are `⌈w/28⌉ × ⌈h/28⌉` on Anthropic after downscale, so a real charge needs the dimensions)
- Downscale at put, or Anthropic Files API `file_id` for sessions that pass 20 images
- Orphan sweep (put with no send)
- Fork and rewind blob behavior (methods unimplemented)
- `read` tool vision
- Audio / PDF put and admission
- MCP tool images

---

## 12. Project constraints (from CLAUDE.md)

- Zig 0.16.0 (`.mise.toml`). `zig build test`, `zig build test-js`, `zig fmt`.
- Naming: `TitleCase` types, `camelCase` fns, `snake_case` fields.
- Comments: one line, STE100. No narration.
- Assert internal invariants; **never assert on wire/peer input**. A bad path, bad hash, bad mime, bad size are operating errors. A non-hex hash **after** admission is an assert.
- Allocation cost on the hot path is measured, not claimed.
- Do it right in scope; staged follow-ons are named, not hidden in TODO comments.
- No Claude co-author trailer if you commit.

---

## 13. Success for the plan (not the code)

The plan is done when a reviewer can see:

- v1 user story: *put a path, get a ref, send the ref, vision model gets pixels; text-only gets the note; a bad ref never commits; remove unlinks.*
- Exact files to touch.
- The full protocol diff: `blob.put`, the `MediaSource` flatten decision, `detail` drop, version bump.
- Store layout, the `blob_refs` table, and the remove ordering.
- Error codes and messages for put, admit, and unresolved-at-prepare.
- Test list (positive and reject).
- The arena measurement plan.
- Named follow-ons (clients, blob read, budget, sweep, fork/rewind, read-tool vision, audio/PDF).
- No client UI work hiding in v1.

If you disagree with the path-based put, the `MediaSource` flatten, or the `blob_refs` table, state the tradeoff in the plan. Do not add a `path` or `bytes` arm to the durable content types.

---

## 14. Review outcomes (2026-09-11, six Luna reviewers by dimension)

The slice is built and green: `zig build test` and `test-js` 747/747, binary builds, schema check passes, eight production mutations each fail a test. Six reviewers (correctness, tests, design, idiomatic, performance, protocol) ran read-only. Reports: `bench/review-2026-09-11/report-*.md`. Every code claim below was verified against the source.

### Fix before commit

1. **`App.close` frees a borrowed path** (`src/app/app.zig:189`, 5 reviewers). `App.open` allocates `blob_dir`; `App.initTest` stores the caller's slice; `close` always frees. No caller hits it today, but the contract is unsafe. Fix: `initTest` dupes the path, so `App` always owns and frees it.
2. **`blob_refs.bytes` is missing** (3 reviewers). Section 5.1 planned a `bytes` column for the context-budget follow-on; the migration dropped it. Add `bytes INTEGER NOT NULL` now, pass `MediaBlob.bytes` through `recordRefs`, and regenerate the query, so the budget pass needs no second migration.
3. **Cancellation becomes a runtime failure** (`src/engine/request.zig:282`, 3 reviewers). `Store.read` returns `Canceled`; `BlobReader` folds it to `null` -> `UnresolvedBlob` -> `runtime`. A canceled run must report canceled. Fix: carry `Canceled` through `BlobLookup.get` and the builder error set, and let `streamRound` handle it.
4. **Blob error names collide and one maps wrong** (`src/app/call.zig`, idiomatic + correctness). `failureFor` takes `anyerror`, so the generic names `Empty`/`TooLarge`/`Unreadable`/`NotRegularFile` would misclassify any other subsystem that raises them (only latent today: skills wrap their reads into `SkillUnreadable`). Also `StoreFailed` is an engine failure mapped to `bad_request`, and `Canceled`/`OutOfMemory` fall through to `internal`. Fix: prefix the put/admit error set (`BlobEmpty`, `BlobTooLarge`, `BlobUnreadable`, ...), map `StoreFailed` to `runtime_failed`, keep `OutOfMemory` as `internal`, and route `Canceled` to the cancellation path.
5. **The caps are not published** (protocol). `max_bytes` (7 MiB) and `max_images_per_input` (8) live only in `src/store/blob.zig`, so the GUI must duplicate policy to pre-check. Fix: add both to `lib/proto/meta.zig limits`, use those constants in the store, regenerate the schema.
6. **Prose: one-line comments that join two ideas** (all reviewers, consensus list). Split or trim each: `content.zig:7`, `blob.zig:5` (proto), `app.zig:31`, `Engine.zig:33`, `commands.zig:521`, `request.zig:281`, `request_builder.zig:19`, `store/blob.zig:1/12/16/39`, `migrations/0005:1`, `blob_test.zig:1`. Also `ids.zig:55` should say "lowercase". A single idea per one-line comment, STE100.
7. **Tests: three gaps** (tests reviewer). (a) The initialize test carries `blob_dir` but never asserts it; add the assertion. (b) "the store is never read" is vacuous: it deletes the source file, but the hash-named blob still exists, so a stray lookup would still succeed. Add a `request_builder` unit test with a spy `BlobLookup` that asserts exact bytes, a null lookup, and a missing hash, and that the omission path never calls it. (c) No test drives `blob.put` or an admission refusal through `call.call`; add one now that the error set changes (finding 4), asserting the `bad_request` wire code and the message.

### Accept as designed (record, do not change)

- **Removal dangling-ref race** (correctness + protocol flagged as blocker). Under one executor a `send`/`create` can admit the same hash and commit its ref in the cooperative window between `referenced` and `unlink`, leaving a ref to a deleted file. It is narrow and it degrades to `UnresolvedBlob` -> a recoverable `runtime` run error, never a crash or data loss. The section 5.1 claim "never dangling" is corrected to: **a removal never crashes; a dangling ref can only arise from a concurrent same-hash admission and degrades to a recoverable runtime error.** A process-wide blob lock or a coordinated GC is the fix when a second writer ever exists; it is a named follow-on, not this slice.
- **No `fsync` before rename** (performance). Deliberate, matching `agent_config`. The temp file is fully written before the atomic rename, so no torn file under a valid hash; power-loss durability is out of scope. The comment claims atomicity, not durability, and is correct.
- **`verify` re-reads after `stat`** (correctness TOCTOU). Local single-user trust model; the source path is an engine-host path by design. Out of scope.
- **Duplicate `recordRefs` at `enqueue` and `appendCommittedMessage`** (raised, all agreed keep). `INSERT OR IGNORE` on the `(session_id, hash)` primary key absorbs it; the two writers cover the queued-only and committed lifetimes.
- **`UnresolvedBlob` message does not name the hash.** Section 5 wanted the hash in the message. Deferred: the hash is not threaded through the builder error today, and the run error already identifies the failing turn. Revisit with the budget follow-on. Brief updated to drop the "names the hash" wording.

### Reviewer suggestions rejected

- **Delete the `// ---- tests` separator.** It is house style (`extensions.zig`, `print_cli.zig`). Keep.
- **Rename `MediaBlob` to `BlobRef`.** Churns the wire and every generated client for no new guarantee. Keep (protocol reviewer agreed).
- **Streaming hash in `put`.** Not justified at a 7 MiB cap; all six agreed to keep the bounded whole-file read. Arena cost is per round (`turn.zig streamRound` frees `round_state` each round), so 8 images never accumulate across a tool loop.
- **`Store` by pointer, `BlobLookup` as a plain function pointer, deriving refs from the event log.** All rejected by design reviewers: `Store` holds a borrowed slice and is cheap to copy; the vtable carries the arena and I/O without global state; `blob_refs` avoids parsing event JSON in the removal path.
