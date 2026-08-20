# yuke-odin — Agent Context

Odin implementation of the yuke wire protocol. Protocol changes must be deliberate and coordinated; pre-release status is not permission for accidental drift.

## Source of truth

- `src/wire/` is authoritative for the Odin wire representation: types, JSON encoding and decoding, validation, method and broadcast registries, and field-level protocol comments.
- Tests define the accepted and rejected encodings. Preserve both positive behavior and strict rejection behavior.
- Treat sibling or predecessor implementations as migration/reference material unless a task explicitly designates a file or revision as authoritative. Do not silently restore behavior from stale or deleted specifications.
- Keep closed protocol sets closed. Do not invent methods, broadcasts, union arms, or fields to make an implementation convenient.
- The project is still **pre-release** it is okay to not be backwards compatible, prioritize better code.

## Script tier (client vs daemon)

Both binaries embed QuickJS through the shared host in `src/js/` (runtime, loader, `yuke:fs` / `yuke:exec` / `yuke:diff`). They install the same host modules and **different** UI and policy modules and entry scripts.

### Shared host (`src/js/`)

- Odin: init/limits, module registry, eval/call/drain, and the host modules `yuke:fs`, `yuke:exec`, `yuke:diff`.
- Not the TUI and not daemon policy. Embedders pass their own `modules`, `base`, pools, and report hook.
- One path rule for every host module (`src/js/path.odin`): a leading `~` expands, a relative path resolves against `Options.base`, and an empty `base` rejects relative paths. **Nothing is contained.** A caller that has `yuke:exec` can reach any file with a command, so a containment check on the file half would buy the appearance of safety rather than safety. Gate the caller instead. `path_contained` remains for an embedder that contains something of its own, such as the client's module loader.
- `Options.exec_pool` is separate because one command holds a worker for its whole timeout. Nil runs commands on `pool`.
- `yuke:exec` spawns `/bin/sh` through `posix_spawn` with `POSIX_SPAWN_SETPGROUP`, so the shell leads its own process group. A timeout or a cancel signals the **group** (`killpg`), because the shell forks the command and a signal to the shell alone leaves the command running. SIGTERM first, then SIGKILL after `EXEC_GRACE`. Do not weaken this to a single-pid kill; `test_exec_kills_the_whole_process_tree` fails when you do.
- `yuke:exec` is refused on Windows. It needs its own `CreateProcessW` (`core:os` quotes command lines by MSVCRT rules that `cmd` does not parse), a shell the model can write for, and a Job Object for the tree kill.
- `src/js/types.d.ts` is the ambient surface for **shared** host modules. Keep it in sync with `fs.odin`, `exec.odin`, and `diff_module.odin`. Client and daemon types reference this file; do not redeclare those modules elsewhere.
- `eval_module` supports **top-level await** of host ops: it drains microtasks and ticks the pool's event loop until the module promise settles or the host deadline elapses. A module that stays pending with nothing in flight fails evaluation.

### Client TUI (`tui` — `src/tui/`)

The `yuke` binary (`src/yuke/`) is a thin `package main` that only dispatches subcommands; the interactive client lives in `src/tui` (`package tui`, entry `tui.run`).

- Baked modules: `core.js`, `ui.js`, `defaults.js`, `app.js` → `yuke:core` / `yuke:ui` / `yuke:defaults`, plus host `yuke:term` and the shared `yuke:fs` / `yuke:exec` / `yuke:diff`.
- `base` is the working directory, which is the workspace in practice, so a client script may name a file relative to the project it edits.
- User overlay: `~/.config/yuke/yuke.js` (and plugins under that config dir).
- `src/tui/types.d.ts` is the ambient TypeScript surface for **client** modules and `globalThis.onEvent`. It references `src/js/types.d.ts` for the shared host modules. It is not runtime code.
- `src/tui/jsconfig.json` pulls those types into the client JS tree for editors.
- **Before changing client JS**, read the relevant sections of `types.d.ts` and the matching `.js` (and the host glue `src/tui/host.odin` / `js.odin` for `yuke:term`).
- **When adding, removing, or reshaping a client JS export** (function, class, method, option field, event shape), update `src/tui/types.d.ts` in the same change. Do not leave the declarations stale.
- Keep ambient types idiomatic: declarations only, minimal commentary (a short file header is enough). Prefer precise types over narrative comments; put behavior and rationale in the `.js` sources or the host glue (`src/tui/host.odin` / `js.odin`).

### Daemon (`yuked` — `src/daemon/script.odin`)

- Script surface today: the shared `yuke:fs` / `yuke:exec` / `yuke:diff` plus `yuke:daemon` (when a script root is configured). No baked UI modules, no `yuke:term`, no `yuke:core` / `ui` / `defaults`.
- No `base`: a daemon serves many workspaces, so a relative path has no single meaning and every script path is absolute. `yuked.js` is loaded from the process config directory (`paths.config_dir`, same folder as the TUI's `yuke.js`). `$YUKE_APPNAME` remaps the config and data leaf for both binaries. That directory locates the entry only; it never bounds what a script reaches.
- User entry: `<config-dir>/yuked.js` at startup (`JS_ENTRY_FILE`). A missing entry is fine; a broken entry fails start. Tests pass `Options.config_dir` to isolate from the developer's config.
- `src/daemon/types.d.ts` is the daemon script ambient surface: it references `src/js/types.d.ts` only. Add daemon-only modules there when the host installs them.
- **Do not treat `src/tui/types.d.ts` as the daemon script API.** Client TUI modules must not appear in daemon types.

## Commands

- `./build.py` holds the canonical build, format, and test commands; run `./build.py help` for what exists rather than assuming a command. Use whatever commands the task needs. A package is declared once in its `PACKAGES` table and picked up by every gate, so add new packages there.
- Format after changing Odin sources and keep the tests green.
- You run in an environment where `ast-grep` is available; whenever a search requires syntax-aware or structural matching, default to `ast-grep --lang odin -p '<pattern>'` (or set `--lang` appropriately) and avoid falling back to text-only tools like `rg` or `grep` unless I explicitly request a plain-text search.
- `./build.py setup` points git at the tracked `.githooks/` (pre-commit runs `schema-check` when `src/wire/` or `schema/` is staged). Run it once per clone/worktree.

## Commit

- Do not add Claude co-authored on commits message.
- Follow project convention of minimal and simple commit message style.

## Odin style

- Match the existing code: `Ada_Case` types and enum values, `snake_case` procedures, and `SCREAMING_SNAKE_CASE` constants.
- Never prefix a declaration with its own package name. The namespace is chosen at the import site, so `daemon.daemon_start` is redundant—it is `daemon.start`. Prefix by *subject* instead: the type or subsystem the declaration acts on (`blob_finalize`, `conn_close`, `ws_on_open`, `FRONT_DOOR_ROUTES`). A package's principal type keeps the package's name (`daemon.Daemon`, `store.Store`), and its options and error enums are plain `Options` and `Error`.
- Prefer explicit `Validation_Error` results and `or_return` over catch-all behavior.
- Let `odinfmt` enforce formatting; do not hand-format around it.
- Prefer `if cond do stmt` over `if cond { stmt }` for single-statement bodies. If the condition combines a type assertion and a bool guard, split onto two lines: assertion first, then the `if cond do` guard.
- Separate logical steps inside proc bodies with a single blank line for human readability. Insert a blank: around a nested type decl (`Field :: enum { … }`), before an `if`/`switch` block opener and after its closing `}`, between consecutive `switch` cases, and before a final `return` at proc-body scope. Do not insert a blank before a `for` loop that follows its own setup line (`seen: bit_set[Field]`, `have := false`, `dec_object_begin(d) or_return`, `array_begin(e)`, or a declaration) — they are one idea. Never insert a blank as the first statement of a block or at file level between top-level declarations.
- In a top-level `:: struct`/`enum`/`union` body where **every** field has a leading `//` doc comment, insert a single blank line between each comment+field unit (comment block, then its field, then a blank). Leave the closing `}` flush (no blank before it). Do not apply this to bodies with any uncommented field, to type decls nested inside a proc body (e.g. `Field :: enum`), or to the wire-string mapping tables (`*_wire := […]`). Match each union arm to the doc comment of its sibling struct where one exists.
- Only ever insert single blank lines; `odinfmt` (`newline_limit: 2`) preserves them and collapses triples, so never create a double blank.
- Never leave a comment floating above a declaration it does not document. `core:odin/parser` merges comment groups separated by a single blank line, so a section banner or stray note silently becomes part of the next declaration's docs — in `wire.json` and in every ols hover. `tools/schema` rejects this for modeled declarations.
- Keep comments minimal. Explain protocol semantics, ownership, compatibility behavior, or non-obvious invariants only—never narrate self-evident syntax or add verbose, redundant commentary.

## Design

- Follow TigerBeetle's "zero technical debt" policy: do it right the first time. The second pass may never happen, and doing work we can be proud of builds momentum. Do not knowingly leave temporary fixes, deferred correctness work, or cleanup debt within the requested scope.
- Prefer concrete, direct code over speculative layers. Extract a helper when it removes meaningful duplication or gives a non-obvious invariant a name, not merely to shorten a call site.
- Design APIs from real callers. Reason about data representation and lifetime before adding control-flow abstractions.
- Keep changes small, reviewable, and within the requested scope.
- When unsure about an external fact—library behavior, an API, a spec detail—verify it by reading the source or doing a web search. Do not assume.

## Collaboration

- Maintain an active, detailed dialogue with the user throughout implementation work. Explain what is being changed, the relevant invariants and lifetimes, the risky paths being checked, and the evidence that supports each conclusion; do not save all substantive communication for the final response.
- Surface assumptions, uncertainty, tradeoffs, and newly discovered constraints as soon as they matter. If a choice could materially change behavior or correctness and the intended answer cannot be established from source, tests, or an explicitly named design document, discuss it with the user instead of silently guessing.
- Share meaningful progress and verification results while working. Continue safe, in-scope investigation and implementation during that dialogue rather than using communication as a substitute for progress.
- Do not declare an implementation complete while relevant uncertainty remains. The final handoff must explain what changed, why it is correct, which failure paths were considered, and exactly how it was verified so the user can confidently evaluate the result.

## Assertions

- Follow TigerBeetle-style assertion discipline: assert liberally. Every proc that operates on internal state should check its arguments, its key invariants, and its impossible branches — aim for a couple of assertions per proc. Assert positive space (what must be true) and negative space (what must never happen).
- Assertions guard internal invariants on already-validated state: state-machine transitions, delta offsets, ordering, finalization, ownership. A failed assertion is a bug in our code — fail fast at the violation site instead of limping on with corrupt state.
- Never assert on wire or peer input. A malformed frame returns a `Validation_Error` and degrades gracefully; it must never crash the daemon. Keep the decode boundary error-return-based; assert on the other side of it.
- A condition is either a programmer error or an operating error, never both: assert it or handle it. Recovery code guarded by an assertion on the same condition is unreachable.
- Use `assert(cond, "msg")` for runtime invariants and `#assert` for compile-time facts (type sizes, table lengths). Keep assertion expressions free of side effects.

## Do not

- Do not persist borrowed frame data without cloning it into its owner.
- Do not require JSON object members to arrive in emitter order.
- Do not weaken required-field, enum, discriminator, or closed-union validation in the name of forward compatibility.
- Do not materialize ignored or unknown broadcast payloads.
- Do not use session-scoped ids as array indices; only `Part_Id` has ordinal semantics.
- Do not construct a permission prompt from `Session_Activity` alone. It is coarse status and a locator; use the matching active-draft `Tool_Part` in `Tool_State_Waiting_Permission` for arguments and permission options.
- Do not add wrappers, layers, or helpers for hypothetical future reuse.
- Do not expand the task into unrelated cleanup.
