# Transcript UI — the evidence, the change, and what remains

Status: record. Source of truth: `src/js/app/transcript.js`. Last verified: 2026-09-09.

The transcript was too verbose. This document holds the evidence that proved it, the prior art that
shaped the fix, the change that shipped, and the work that remains.

## 1. The problem

A screen of one session showed about 46 rows. About 20 of them were the single word `thought`. Every
other row was `exec <raw shell pipeline>` and ended in `done · 66ms`.

Three causes stacked.

**A collapsed thought rendered its own name, not its content.** `reasoningRows` built a header row
whose text was the literal `thinking` or `thought`, then returned early when the part was collapsed.
`groupingRole` classed reasoning as `ROLE_ACTION`, so every reasoning part took its own row. A
provider emits a reasoning part between every tool call, so the transcript alternated action, label,
action, label.

**`exec` showed the raw command.** `toolSummary` returned `o.command` unchanged. For `read` it
returned `o.path`, which read well. For `exec` it was a 300-character pipeline that held environment
assignments and an absolute interpreter path.

**Every row paid for a status it did not need.** `toolHeaderRow` always appended the state label and
`duration_ms`. On success, `done` repeated what the absence of an error already said. `66ms` was not
a fact a reader acts on.

`TxToolName` was `fg bold` and all other groups were `fg dim`, so no hue separated a file read from
a shell exec.

## 2. Evidence from the session store

These counts come from `~/.local/share/yuke/yuke.db`, over 255 reasoning parts.

| protocol / model | parts | shape |
| --- | --- | --- |
| `openai_responses` — gpt-5.6-luna, gpt-5.6-terra | 262 | title-only 176 (67%), title and body 76 (29%), empty 10 (4%) |
| `anthropic_messages` — minimax/MiniMax-M3 | 3 | untitled prose, 0% titled |

An OpenAI reasoning summary starts with a bold title, for example
`**Clarifying response constraints**`. The title length is 15 to 63 characters, median 39.

Two results drove the design.

1. **67% of the reasoning parts hold nothing but the title.** For those parts the collapsed row
   carries all of the content, so the expansion is unnecessary.
2. **The bold title is an OpenAI Responses artifact.** Anthropic-protocol reasoning is prose with no
   title. `ReasoningPart` in `lib/proto/message.zig` is `{ id, text, signature }` and holds no
   timing, so a yuke fallback must come from the text.

## 3. Prior art

Five harnesses were read at source level.

| harness | language | files read |
| --- | --- | --- |
| xai-org/grok-build | Rust, ratatui | `xai-grok-pager-render/src/appearance/config.rs`, `render/tool_paths.rs` |
| anomalyco/opencode | TypeScript, OpenTUI | `packages/tui/src/routes/session/index.tsx`, `context/thinking.ts`, `util/collapse-tool-output.ts` |
| charmbracelet/crush | Go | `internal/ui/chat/{tools,bash,assistant}.go` |
| openai/codex | Rust | `tui/src/exec_cell/render.rs`, `tui/src/exec_command.rs`, `shell-command/src/parse_command.rs` |
| esengine/DeepSeek-Reasonix | Go | `internal/cli/{toolcard,chat_tui}.go` |

Note: the opencode repository moved from `sst/` to `anomalyco/`. "th3code" is not a TUI; T3 Code is
a web GUI over Codex and Claude Code. `superagent-ai/grok-cli` is a community wrapper;
`xai-org/grok-build` is the xAI harness and holds the real design.

### 3.1 No harness renders a content-free reasoning row

- **opencode** shows `+ Thought: Inspecting PR workflow · 4s`. It takes the title with
  `^\*\*([^*\n]+)\*\*` from the provider summary.
- **crush** shows the last 10 lines of the reasoning plus `… (N lines hidden)`, and a footer
  `Thought for 12s`.
- **grok-build** folds to `Thought for Xs`, dim and italic over a `bg_blend: 0.7` fade.
- **Reasonix** shows a live `▎ thinking…` line and rewrites it to `▎ thought for Ns`.

yuke was the only one that printed the bare word.

### 3.2 No harness uses the raw command as the label

- **codex** parses the command into `Read{name,path} | ListFiles | Search{query,path} | Unknown`,
  then renders `Read foo.rs`, `Search TODO in src/`, or `Run <cmd>` with a cyan verb. It strips the
  `bash -lc` wrapper and makes paths relative to `$HOME`.
- **Reasonix** holds two static maps, `toolVerb` and `toolArgKey`, and renders `● Verb(arg)`.
- **crush** strips `cd <workingDir> && `, flattens newlines, and renders `● Bash <cmd> (k=v)`.
- **grok-build** collapses a Read or Edit path to the basename.

All four render the worst row in the screenshot as `Run zig build test-js`.

### 3.3 The right-hand detail is a result size, not a duration

grok-build documents the vocabulary: Read `(1-50)`, Search `(N matches)`, Edit `(N edits)`.
Reasonix collapses a finished tool to `⎿ N lines`. No harness puts a per-tool duration on a
collapsed row. A duration attaches to a thought, where there is nothing else to say.

### 3.4 Output caps land at 2 to 10 lines

codex `TOOL_CALL_MAX_LINES = 5`, and 50 for a user shell. crush `responseContextHeight = 10`.
grok-build `first_lines: 2, last_lines: 3`. Reasonix 10 for a shell. yuke `ACTION_PREVIEW_ROWS = 3`
is already in that range. **This was never the problem.**

### 3.5 Consecutive read-only actions merge

codex merges a run of read-only calls into one `Explored` block. Inside that block it folds
consecutive reads into a single line, `Read a.rs, b.rs, c.rs`, with a `.unique()` filter
(`exec_cell/render.rs:271-305`).

### 3.6 Defaults

opencode sets the thinking mode to `hide` for a new user and carries a migration for the legacy
flag (`context/thinking.ts:50-55`). Claude Code kept expanded-by-default and closed the request to
change it (anthropics/claude-code issue #40428, closed as not planned).

## 4. What shipped

### 4.1 The rows

- A collapsed thought reads `thought · <title>`. The title comes from the `**bold**` prefix, and
  prose falls back to its first line. `TITLE_MAX` bounds it at 72 characters.
- An empty reasoning part renders nothing. It also takes no place in its action group, so the
  `N actions` count no longer counts it.
- `exec` reads `Run <program> <arguments>`. The label drops leading `#` comment lines and leading
  `NAME=value` assignments, reduces the program to its basename, makes a path under the process
  directory relative to it, and holds one line. `COMMAND_MAX` bounds it at 160 characters.
- A completed call shows no state word. A duration appears only over one second, as `1.4s`.
- The other state words stay: `running`, `error`, `canceled`, `setup declined`, `setup incomplete`.

### 4.2 The seam

Two objects are public from `yuke:transcript`.

```js
export const presenters;   // tool name -> { category, present(args, raw) -> { verb, subject } }
export const presentation; // { fallback(part, args, raw), role(part) }
```

`presenters` holds one record per tool. `category` is static data, because the action plan reads it
without a parse. `present` is a method, so `ctx.advise` reaches it, and a plugin reload replaces it
in place. A new tool registers a record under `ctx.effect`, which reverts the entry on dispose.

`presentation.role` replaced the private `groupingRole`, so a user who does not want the action
groups assigns a policy instead of a fork. `presentation.fallback` names the row every third-party
tool takes, and it was invisible before.

`ROLE_NONE`, `ROLE_ACTION` and `ROLE_TEXT` are public, because a policy returns them.

The renderer keeps the layout, the source offsets, the row tags and the preview limits. A presenter
returns strings only, so a table cannot break a selection.

**Two rules hold for every presenter.** `present` must not walk tool output, and it must not scan a
whole text. Section 5 holds the measurements behind both.

### 4.3 The theme

`ui.js` gained `TxToolRead`, `TxToolWrite`, `TxToolRun` and `TxToolAgent`. Each starts as the plain
`TxToolName` style. The default palette in `core.js` is monochrome. `danger` is the only colour, so yuke adds no
colour. A theme plugin now separates the categories without a change to
the renderer.

### 4.4 The action tree stays

The `├─ │ └─` spine, the `N actions` header and the five-column indent remain the defaults. No
other harness draws a spine. It costs three columns on every action row, so it is worth another
look.
`presentation.role` makes that a policy question now, not a fork.

## 5. Performance limits

**QuickJS takes about 0.8 µs for a string method call.** There is no JIT. On one full render, a
`toolMagnitude` function counted output rows with `indexOf("\n")`. It made 11,688 calls over
0.72 MB of tool output and cost **9.3 ms**. That was 87% of a 10.7 ms regression.

Three rules follow.

- **The renderer must never walk tool output.** A result size, for example "214 lines" or
  "37 matches", belongs on `ToolState` as a field the engine fills. That is a protocol change. It
  needs a decision.
- **Never copy a whole part text on a hot path.** `groupingRole` cost about 6 ms when it called
  `.trim()` on every reasoning text on every action-plan build.
- **Compute a body only when a row needs it.** A summary returns the title and a body offset. It
  does not slice and trim the body while the part is collapsed.

Two more measured costs, for reference: a `/\s+/g` replace over every command cost 3.2 ms, and the
`clip` and `term.measure` calls in the reasoning header cost about 1 ms.

### 5.1 The cost of the change

The label work was measured against the old label work, interleaved A/B, six rounds, minimum of
each, over the 98 tool arguments and 77 reasoning texts of `bench/transcript-fixture.json`.

| pass | per full render |
| --- | ---: |
| old `toolSummary` plus the bare `thought` word | 0.147 ms |
| new `describe` plus `reasoningTitle` | 0.532 ms |
| delta | **+0.385 ms** |

That is about 3% of the recorded 13 ms cold layout. It is far under the costs above. The render
cache pays it once for each part and width change, not once for each frame.

## 6. The benchmark

`bench/` is not tracked. `zig build bench -Doptimize=ReleaseFast` runs `src/bench.zig` over
`bench/transcript-fixture.json`: 84 messages, 77 reasoning parts, 98 tool parts, 918 KB. The phases
are `paint`, `selection`, `preview`, `projection` and `gc`. Each phase runs five trials.

**This machine has about ±20% run-to-run noise.** A single run proves nothing. One single-run probe
put `toolMagnitude` at 0.8 ms when the true cost was 9.3 ms. Always interleave the variants
(A, B, A, B, A, B) in one loop. Compare the lowest result of each variant.

## 7. What remains

1. **Merge consecutive read-only actions**, as codex does. `_buildActionPlan` already segments
   the right spans, and `presentation.merge` is the place for the predicate. It must decide by tool
   name through `presenters[name].category`, never by parsed arguments, because the plan walks every
   part on every rebuild. **This is the only change that reduces the row count.** A full render of
   one real session holds 252 rows. The changes in 4.1 raise the information per row. They do not
   remove rows.
2. **Add the result size to `ToolState`.** Without it there is no right-hand detail, because the
   renderer must not count rows. This is a `lib/proto/` change and needs a deliberate decision.
3. **The action tree spine.** See 4.4. A capture of a stored session at 80 columns settles it with
   no model call.
4. **Add a `ctx.transcript` namespace** if the raw `ctx.effect` and `ctx.advise` forms prove
   awkward for a real plugin. It is sugar over a capability that already works, so it is additive.

## 8. Verification of the shipped change

- `zig build test-js`: 658 of 658 pass. `zig build test`: 1031 of 1031 pass.
- New tests: the bold title, the empty-reasoning skip, the `exec` label, the unknown-tool fallback,
  a presenter override that moves the row and the source together, and a presenter fault that falls
  back.
- One session from the store rendered in an isolated TUI. The run used a copy of the database and
  an empty config directory. The capture showed `Run ls -la docs/herdr.md && wc -l docs/herdr.md`,
  where the old build showed two absolute paths. It also showed `thought · <title>` in place of the
  bare word.
