# yuke

Unleash you harness.

## Development

- Zig **0.16.0**

```sh
mise install
git config core.hooksPath .githooks
```

## Commands

```sh
zig build test          # build and run all tests
zig build test-js       # run the process and QuickJS host tests
zig build               # compile yuke
zig build gen-schema    # regenerate schema/proto.json from the Zig types
mise run types          # regenerate the plugin declarations in src/js/app/generated
zig build sqlgen -- --migrations <dir> --queries <dir> --queries-out <file>
```

## JSONL RPC

Run `yuke --rpc` for a local JSONL client on stdin and stdout.
`initialize` is optional version discovery. It accepts empty parameters and reports the server protocol version.
A client can call it before other methods to check compatibility. The server has no version handshake or client-version field.

## Plugin types

`yuke types` writes the plugin API declarations into the profile's configuration directory, next to `index.js`:

- `yuke.d.ts` and `yuke-modules.d.ts` declare `yuke`, `yuke:ui`, `yuke:chat`, and `yuke:plugins`.
- `jsconfig.json` makes the editor check `index.js` against them. The command writes it only when none exists.

Run `yuke types` again after an upgrade. For another profile, set its name: `YUKE_APPNAME=work yuke types`.

## Agent configuration

Child agents come from the `agents` plugin. Install it in the profile's `index.js`:

```js
import { plugins } from "yuke";
import { agents } from "yuke:plugins";

plugins.use(agents({
  catalog: {
    research: { description: "Narrow research and simple edits.", tools: ["read", "exec"] },
    review: { description: "Broader work and review." },
  },
  default: "research",
  maxDepth: 2,
  maxConcurrent: 8,
  maxRounds: 50,
}));
```

Each catalog key names one kind of child. A key is lowercase, and `root` is reserved.
A row can set `description`, `model`, `prompt`, and `tools`.
A row without `model` runs on the model of its parent session.
`tools` limits the child to a subset of `read`, `write`, `edit`, `exec`, and `skill`.
`default` names the row a spawn uses when it names none. A catalog with one row needs no `default`.

Use `/agents` to see the main conversation and all descendant agents, switch sessions, or stop agent work.

The root has depth zero. `maxDepth` defaults to `1`, which permits direct children.
A value of `2` also permits grandchildren. `maxRounds` caps each child run; a capped run reports partial output.
All three limits require positive 32-bit integers.
At the depth limit, spawn tools are absent and native child creation fails.

`maxConcurrent` defaults to `8`. It applies to active descendants across the whole tree and excludes the root.
A child keeps its slot until native cleanup ends. Excess work enters the durable queue.
If an agent has no independent work, it can return its result to free a slot.
An agent report starts a follow-up after its owner becomes idle and capacity is available.
Disposing the plugin restores the previous limits.

A lower depth limit prevents new spawns. Existing sessions, queued work, and reports remain valid.
Names are local to each parent. Use a child name or session ID to address a child.

## License

MIT
