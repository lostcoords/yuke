# Named agent catalog

Status: not started.

Date: 2026-09-10

This plan supersedes `docs/subagent-profiles.md`.

The project is pre-release. The plan deletes the slot system. It does not keep a compatibility path for `{ "models": { "small", "medium" } }`. An old `agents.json` is `BadAgentConfig`. The first interactive spawn writes a new file.

## Goal

A child is a named catalog row, not a size slot and not a name that the parent model invents.

Today `agents.json` stores two slots. `spawn_agent` takes `model: small | medium` and a unique session `name`. The parent model invents both. Small models then repeat the delegated work, or they call `sleep` to wait, because spawn returns a receipt and the parent turn stays open.

After this work:

1. The user owns a catalog of agents in `agents.json`.
2. Each row has a name, a model, and optional description, prompt, and tool allowlist.
3. `spawn_agent` takes a task and an optional catalog key. It returns a session id.
4. Follow-up tools address the child by that id.
5. The engine ends the parent run after a successful spawn. The child report starts the next parent turn.

TUI and RPC write the whole file. The file is not a markdown tree and not an editor dump.

## Evidence

Three `spawn_agent` calls in `~/.local/share/yuke/yuke.db` (2026-09-10):

1. Luna spawned `overview` with `model: small`, then did the same investigation (6 `exec`, 9 `read`) while the child ran.
2. MiniMax spawned `wmr-sync-deep-analysis`, then polled with `list_agents` and `sleep 30` / `sleep 60`. The user said the parent wakes when the child finishes.
3. Luna spawned `bench_usage`. Spawn failed (`agents.json` is invalid). The parent did the work itself. That case is a failed spawn, not the wait leak.

The old spawn receipt said "A report will resume this turn". It did not tell the model to end its turn. On 2026-09-11 Opus 5 spawned two children, then read the same files, polled `list_agents` four times, stopped one child, and answered alone. The leak is not only a small-model problem. The receipt now says "After you start every child, end your turn and wait". The engine pause is still the fix, because copy alone does not stop a model.

## Locked decisions

| Decision | Choice |
|---|---|
| Catalog vs instance | Catalog key in `agents.json`. Instance id is `session_id`. |
| Spawn args | `{ message, agent? }`. No session `name`. No slot `model`. |
| Receipt | `{ session_id, agent, model, state, note }` |
| Follow-up | `child` is a 32-hex session id only |
| Reasoning | Always inherit the parent. No field on the row. |
| Prompt | Optional. Append after `default_child_instructions`. Never replace the report contract. |
| Tools | Optional allowlist of builtin names. Omit means all builtins except `spawn_agent`. |
| Description | Optional in the file. The live tool lists `name: description`. |
| Empty catalog | Interactive create. Default name `small`. User selects the model. Headless returns `setup_required`. |
| Unknown `agent` | Error. Spawn does not create a catalog row. |
| Writers | `agents.get` / `agents.update` and the TUI. No markdown agents. |
| Spawn timing | Async receipt. Report later. No `background` parameter in this slice. |
| Parent after spawn | End the run. Do not call the parent model again until a report or user input. |

## Out of scope

- OpenCode `permission` (`allow` / `ask` / `deny`)
- `mode` primary vs subagent
- Temperature, color, steps, variant
- Per-row `max_rounds` (the process keeps `config.agents.maxRounds`)
- Built-in `explore` / `worker` rows
- Project-level agent files
- Blocking spawn
- A wait tool

## Catalog file

Path stays `$configDir/agents.json`. Revision stays SHA-256 of the raw bytes. Update keeps the file lock and the CAS on `revision`.

### Shape

```json
{
  "default": "small",
  "agents": {
    "small": {
      "description": "Default child. Narrow research and simple edits.",
      "model": "minimax/MiniMax-M3"
    },
    "review": {
      "description": "Read-only review. Report issues; do not edit.",
      "model": "openai-codex/gpt-5.6-luna",
      "prompt": "Review diffs for correctness and missing tests. Severity order, file:line.",
      "tools": ["read", "exec"]
    }
  }
}
```

### Validation

Parse is strict. An unknown field is `BadAgentConfig`.

Catalog key:

- Length 1 to 64.
- First character is `a-z`.
- Later characters are `a-z`, digits, `_`, or `-`.
- The key is not `root`.

This is `admission.validName`.

Row fields:

| Field | Required | Rule |
|---|---|---|
| `model` | yes | Nonempty. Length at most 4096. `model_config.validate` on update and on spawn. |
| `description` | no | String. One line in the spawn tool list. |
| `prompt` | no | String. Appended after the expanded child policy at create. |
| `tools` | no | Array of unique builtin names. Empty array is invalid. |

Allowed tool names: `read`, `write`, `edit`, `exec`, `skill`. `spawn_agent` is never in the list. A child never receives spawn tools (`can_spawn` stays false at depth).

`default`:

- Zero agents: omit `default`. The catalog is empty.
- One agent: omit `default`, or set it to that key.
- Two or more agents: `default` is required and must name a key.

A missing file or `{}` is an empty catalog. That is valid. It is not `BadAgentConfig`.

An old file with `models.small` / `models.medium` fails as an unknown field.

## Spawn contract

### Tool description

Static text in `src/js/app/agent-tools.js`:

> Start a child on one self-contained task. Pass `agent` from the list below. This call returns when the child starts. The report comes later as a new message. Start every child you need, then end your turn and wait. Do not do the delegated task yourself.

Live tail, rebuilt each parent request from `agents.json` in `src/engine/request.zig` after `getDecls`:

```
Agents:
- `small`: Default child. Narrow research and simple edits.
- `review`: Read-only review. Report issues; do not edit.
```

If a description is empty, the line is `- \`name\``. If the catalog is empty, omit the tail.

Do not put `prompt` or `tools` in the parent tool text. Do not freeze the list at `defineTool`. `Tools.register` copies the description once. `getDecls` already runs per request.

### Parameters

```
message  string, required, minLength 1
agent    string, optional, catalog key
```

`additionalProperties` is false.

Resolution:

1. If `agent` is set, look up that key. Missing key → `UnknownAgent`.
2. If `agent` is omitted and the catalog has one row, use that row.
3. If `agent` is omitted and `default` is set, use `default`.
4. If the catalog is empty, JS runs the create flow (interactive) or the tool returns `setup_required` (headless).

### Native create

`ChildSession` becomes `{ agent: []const u8, site: ToolSite }`. Delete `slot` and the instance `name` on this struct.

`session.create` with `child`:

1. Reject empty initial input (`BadChild`).
2. Reject `reasoning` (`ChildReasoningDerived`).
3. Resolve `child.agent` in the catalog (`UnknownAgent` or `AgentSetupRequired` if empty).
4. Validate the row model with parent reasoning (`inherit`).
5. Reject `params.model` if it disagrees with the row model (`AgentConfigConflict`), same as today.
6. Enforce depth and report capacity.
7. Persist `sessions.name = catalog key` and `sessions.agent = catalog key`.
8. Expand `default_child_instructions` (or `engine.child_instructions`) with `${agent_name}` = catalog key.
9. If the row has `prompt`, append it after that policy, separated by a newline.
10. `max_rounds` stays `config.agents.maxRounds`.

Two children of one parent may share the catalog key `small`. Identity is the session id.

### Receipt

```json
{
  "session_id": "01a089acf4477d8799dac119d758c9ca",
  "agent": "small",
  "model": "minimax/MiniMax-M3",
  "state": "started",
  "note": "Child started. The report comes later as a new message. After you start every child, end your turn and wait. Do not redo this task."
}
```

`state` stays the input result (`started` or `queued`).

### Follow-up

`send_agent_input` and `stop_agent` take `child` as a 32-hex session id. `ownedChild` stops accepting a catalog name.

Delete `SessionGetParams.child_name`. A shared catalog key makes name lookup ambiguous.

`list_agents` still lists children of the parent. Each row already has `session_id`. Keep `name` on the row as the catalog key.

Reports stay `Report from {name}, run {d}…`. `{name}` is the catalog key. The UI keys rows by session id (`agents-ui.js` already does this).

## Engine pause

`src/engine/turn.zig` `commitRound` today:

```
wants_next = success and (hasToolPart(live) or pending > 0)
```

A spawn receipt is a tool part, so the parent model gets another round. That is the leak.

New rule: if this round contains a completed `spawn_agent` (or any tool with `spawns_agents`) and that call is not an error, then `wants_next` is false, except when other queued user input already exists.

Then:

1. Commit the assistant message and the tool results.
2. End the run with finish `stop` (not another provider call).
3. The child report later enqueues parent input and starts a new turn.

Failed spawn, declined setup, or canceled spawn does not pause. The parent may continue.

Same-round parallel calls stay legal: `spawn_agent` plus `read`, or two `spawn_agent` calls. The engine settles every tool in that round, then stops.

Do not add `wait_agent`. Do not document `sleep`.

## Proto

File: `lib/proto/agents.zig`.

Delete `AgentModelSlot`, `AgentModel`, `AgentModels`.

Add `AgentProfile` (`description`, `model`, `prompt`, `tools`), `AgentsConfig` (`default`, `agents` map). JSON on disk is an object map under `agents`. In-memory form may be a sorted list. Custom `jsonParseFromValue` stays strict.

Keep `AgentsGetResult` and `AgentsUpdateParams`.

`lib/proto/session.zig`: `ChildSession.agent` replaces `slot` and instance `name`. Delete `child_name` on `SessionGetParams`.

`lib/proto/registry.zig`: drop `AgentModelSlot`. Add the new types. Run `zig build gen-schema`.

New engine error `UnknownAgent` maps to `bad_request` in `src/app/call.zig`. Delete `DuplicateChildName` once nothing raises it.

## Store

`sessions.agent` already exists (`0001_initial.sql`) and is unused. Store the catalog key there.

`sessions.name` stays required for a child (CHECK from `0003_child_admission.sql`). Store the same catalog key. Reports and `${agent_name}` keep working.

Migration `0005_agent_catalog.sql`:

1. `DROP INDEX IF EXISTS sessions_child_name`.
2. Add a CHECK: a child has `agent` and `name` both set and equal; a non-child has both null.
3. Align `agent` grammar with `name` (length, charset, not `root`).
4. `UPDATE sessions SET agent = name WHERE origin = 'child' AND agent IS NULL` so current sessions still open.

Delete query `child_by_name` after `session.get` no longer uses it.

## Tool allowlist

`toolset.Selection` gains `allow: ?[]const []const u8`.

`request.selectionFor`:

- Root: `allow = null` (all visible tools, spawn gated by depth).
- Child: load catalog by `sessions.agent`. If the row has `tools`, set `allow` to that list. If the row is gone, keep builtins except spawn (catalog edit must not trap a live child with zero tools). Document this fallback.

`src/js/port.zig` `declsFor` / `isAllowed`: when `allow` is set, drop any tool whose name is not in the list. Spawn flags still apply.

A tool call outside the allowlist is not advertised. If the model names it anyway, `isAllowed` is false and the existing unknown/forbidden path answers.

A catalog edit applies on the next child round. The prompt is snapshotted at create. That split is acceptable for v1. Do not add a tools column on `session_configs` in this slice.

## JS and TUI

### `agent-tools.js`

- Spawn fields: `message`, optional `agent`.
- Receipt as above.
- `ownedChild`: 32-hex id only.
- `child` field description: `Child session ID.`

### `agents.js`

Delete the slot enum, the both-slots confirm, and spawn `name` / `model`.

Keep `pickModel` for catalog create and edit.

`spawnAgent(ctx, { message, agent? }, …)`:

1. `agentsGet`.
2. Empty catalog → `createCatalogEntry` (interactive) or throw `setup_required`.
3. Resolve the row.
4. `sessionCreate` with `child: { agent, site }`.
5. On `auth_required` / `unsupported_model`, repair as `withSlot` does today, then retry.

Interactive create:

1. Confirm: configure agents now?
2. Name input, default `small`, validate with `NAME`.
3. Model picker (same as today).
4. `agentsUpdate` with `{ default: name, agents: { [name]: { model } } }`.
5. Continue spawn.

### `agents-ui.js`

`/agent-models` becomes a catalog editor:

- List rows: name, model, default mark, tool summary.
- Add: name, description, model, optional prompt, optional tools.
- Edit: same fields.
- Delete: refuse if it is the last row and a child still uses it, or refuse if it is `default` until the user picks another default.
- Set default.

`/agents` stays the live child tree. Display catalog key plus model. Key rows by session id.

### Transcript

```
spawn_agent  → Agent  {agent} · {model}
send_agent_input → Send {child}
stop_agent → Stop {child}
```

`inputSourceLabel` for reports stays `Message from ` + catalog name.

## RPC

Methods stay `agents.get` and `agents.update`. The payload is `AgentsConfig`.

`session.create` child arm uses `agent` instead of `slot`+`name`.

`session.get` no longer takes `child_name`. Callers pass the child session id.

## Tests

### Proto and config

- Round-trip of the example file.
- Unknown field fails.
- Empty `tools` fails.
- Tool name `bash` fails.
- Duplicate tool name fails.
- Two agents without `default` fail.
- `default` that names no key fails.
- `{}` succeeds as empty.
- Old `{ "models": { "small": { "model": "x" } } }` fails.

### Engine

- Create with `child.agent` stores `sessions.agent` and `sessions.name`.
- Two children with `agent = small` succeed.
- Unknown agent fails.
- Child with `tools: ["read"]` does not advertise `write` or `exec`.
- Parent round with completed `spawn_agent` does not start a second model call.
- `session.get` with `child_name` is gone.
- Prompt append: stored child policy contains the default contract then the row prompt.
- Reasoning on the child equals the parent.

### JS

- Schema requires `message`. It does not require `model`. It does not require `name`.
- Receipt has `session_id` and `agent`. It has no minted handle.
- `send_agent_input` with `child: "small"` fails.
- Spawn tool description contains `- \`small\`` when the fixture catalog has `small`.
- Empty catalog in an interactive fixture runs create then spawn.
- `/agent-models` lists rows and can add one.

Update or delete slot assertions in:

- `src/js/agents_test.zig`
- `src/js/tests/agents/coalesce.test.js`
- `src/js/tests/agents/refusals.test.js`
- `src/js/tests/agents/nested.test.js`
- `src/js/tests/agents/fixture.js`
- `src/js/tests/agents/edit-slot.test.js`
- `src/js/tests/agents/owner-question.test.js`
- `src/engine/model_config_test.zig`
- `src/engine/admission_test.zig` (duplicate name)
- inline `session.get` `child_name` test in `src/engine/commands.zig`

## Work order

1. Proto, strict parse, migration, `zig build gen-schema`. Engine types compile. Old JS still needs a follow-up in the same change set because `ChildSession` breaks spawn.
2. Engine: resolve catalog, persist `agent`, append prompt, allowlist on `Selection`, pause after spawn. Zig tests green.
3. JS tools, receipts, id-only follow-up. Engine injects the live description.
4. TUI catalog editor and empty-catalog spawn flow.
5. `zig fmt`, `zig build test`, `zig build test-js`.

Do not split proto from engine in a way that leaves `main` unable to spawn. One stack is fine if the diff stays reviewable. If you split, land proto+engine first with JS in the same PR.

## Risks

- Tool description changes when `agents.json` changes. Provider prompt cache sees a new prefix. That is intended.
- Two children share a catalog key. Reports share that word. Follow-up uses id. The `/agents` picker already keys by id.
- Headless with an empty catalog cannot prompt. Pre-fill `agents.json` or call `agents.update` first.
- Invalid `agents.json` stays a hard error. Empty is not invalid. The `bench_usage` failure was invalid JSON/shape, not an empty catalog.
- A catalog row deleted while a child runs: next round falls back to all builtins except spawn. The snapshotted prompt stays.

## Files that change

Proto and schema: `lib/proto/agents.zig`, `lib/proto/session.zig`, `lib/proto/registry.zig`, `lib/proto/rpc.zig` if needed, `schema/proto.json` (generated), `src/js/app/generated/proto.d.ts` (generated).

Engine: `src/engine/agent_config.zig`, `src/engine/commands.zig`, `src/engine/request.zig`, `src/engine/turn.zig`, `src/engine/toolset.zig`, `src/engine/admission.zig` if name helpers move, `src/app/call.zig`, `src/js/port.zig`.

Store: `src/store/migrations/0005_agent_catalog.sql`, `src/store/queries/session.sql`, generated queries.

JS: `src/js/app/agent-tools.js`, `src/js/app/agents.js`, `src/js/app/agents-ui.js`, `src/js/app/client.js`, `src/js/app/transcript.js`.
