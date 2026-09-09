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
zig build sqlgen -- --migrations <dir> --queries <dir> --queries-out <file>
```

## JSONL RPC

Run `yuke --rpc` for a local JSONL client on stdin and stdout.
`initialize` is optional version discovery. It accepts empty parameters and reports the server protocol version.
A client can call it before other methods to check compatibility. The server has no version handshake or client-version field.

## Agent configuration

Use `/agents` to see the main conversation and all descendant agents, switch sessions, or stop agent work.
Use `/agent-models` to choose the small and medium models from your providers.
Small handles narrow research and simple edits. Medium handles broader work and review.

Set agent limits in the profile's `index.js`:

```js
import { defineConfig } from "yuke";

export default defineConfig({
  agents: {
    maxDepth: 2,
    maxConcurrent: 8,
    maxRounds: 50,
  },
});
```

The root has depth zero. `maxDepth` defaults to `1`, which permits direct children.
A value of `2` also permits grandchildren. `maxRounds` caps each child run; a capped run reports partial output.
All three limits require positive 32-bit integers.
At the depth limit, spawn tools are absent and native child creation fails.
Custom tools can set `spawnsAgents: true` to use the same tool policy.

`maxConcurrent` applies to active descendants across the whole tree. It excludes the root.
A child keeps its slot until native cleanup ends. Excess work enters the durable queue.
If an agent has no independent work, it can return its result to free a slot.
An agent report starts a follow-up after its owner becomes idle and capacity is available.

A lower depth limit prevents new spawns. Existing sessions, queued work, and reports remain valid.
Names are local to each parent. Use a child name or session ID to address a child.

## License

MIT
