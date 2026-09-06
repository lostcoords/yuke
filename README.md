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
zig build test-js       # run the QuickJS host tests
zig build               # compile yuke
zig build gen-schema    # regenerate schema/proto.json from the Zig types
zig build sqlgen -- --migrations <dir> --queries <dir> --queries-out <file>
```

## Agent configuration

Set agent limits in the profile's `index.js`:

```js
import { defineConfig } from "yuke";

export default defineConfig({
  agents: {
    maxDepth: 2,
    maxConcurrent: 8,
  },
});
```

The root has depth zero. `maxDepth` defaults to `1`, which permits direct children.
A value of `2` also permits grandchildren. Both limits require positive 32-bit integers.
At the depth limit, spawn tools are absent and native child creation fails.
Custom tools can set `spawnsAgents: true` to use the same tool policy.

`maxConcurrent` applies to active descendants across the whole tree. It excludes the root.
A child keeps its slot until native cleanup ends. Excess work enters the durable queue.
If a parent has no independent work, it can return its result to free a slot.
A child report starts a parent follow-up after the parent becomes idle and capacity is available.

A lower depth limit prevents new spawns. Existing sessions, queued work, and reports remain valid.
Names are local to each parent. Use a child name or session ID to address a child.

## License

MIT
