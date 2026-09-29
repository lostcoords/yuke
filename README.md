# yuke

Unleash you harness.

## Development

- Zig **0.16.0**

```sh
mise install
git config core.hooksPath .githooks
mise run install
```

`mise run install` builds an optimized Yuke, installs it at `~/.local/bin/yuke`, and refreshes the plugin types.

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

- `yuke.d.ts` and `yuke-modules.d.ts` declare `yuke`, `yuke:ui`, `yuke:chat`, `yuke:session`, and `yuke:plugins`.
- `jsconfig.json` makes the editor check `index.js` against them. The command writes it only when none exists.

Run `yuke types` again after an upgrade. For another profile, set its name: `YUKE_APPNAME=work yuke types`.

## Check a profile

`yuke check` loads the profile as the TUI does, without a terminal, and prints each warning and error to stderr.
A plugin block that needs the TUI runs too, so the check finds an error that `--rpc` and `-p` never reach.
A plugin question gets a denial, as in `-p`. The check waits up to 2 seconds for an async plugin startup.
The command exits with 1 when an error occurs, and with 0 when no error occurs.
The check is not read-only: it runs your plugins and opens the session store.

## Event types

A plugin names its own events `<plugin>:<name>`. To type one, add a `.d.ts` file next to `index.js`:

```ts
declare module "yuke" {
  interface Events {
    "herdr:state"(state: "idle" | "working" | "blocked"): void;
  }
}
export {};
```

Then `ctx.on("herdr:state", …)` and `events.emit("herdr:state", …)` check their arguments. An event without a declaration takes any arguments.

## Change the chat

The `sessions` plugin owns the engine sessions: pins, input, activity, the session list, the default model, and the session commands.
The `chat` plugin owns only the chat pane. The shell asks the `chat` service for each new pane.
The bundled features read the parts of a pane, not the `chat` plugin:

- The queue, jobs, agents, context, cache, and the indicator read `currentSession()` from `yuke:session`.
- composer-vim reads the composer of the focused pane.
- transcript-vim and the slash menu read the focused pane when it is a `ChatView`, because the composer and transcript regions are `ChatView` parts.

Use the smallest level that does the job:

1. Advice. Change one method of `ChatView` or `Session` with `ctx.advise`.
2. Events. Answer `chat.rule`, `chat.strip`, `chat.cursor`, or `chat.press`. Name tool calls with `ctx.chat.labels`.
3. Your own pane. Replace the `chat` service. It provides `create(session)` and `labels(entries)`.
   A pane holds a `Session`, a `Transcript`, and a `Composer`. It calls `session.join(this)` once, and the session layer calls `leave` when the pane closes.
   The bundled `chat` plugin also owns `chat:new`, `chat:paste-image`, and the vision warning. A replacement brings its own.
4. Your own window layout. Replace the `shell` plugin.

This `index.js` replaces the chat pane with one that keeps a margin:

```js
import { plugins } from "yuke";
import { Session } from "yuke:session";
import { ChatView, registerLabels } from "yuke:chat";

class RoomyChat extends ChatView {
  layout(bounds) {
    super.layout({ ...bounds, x: bounds.x + 2, w: Math.max(0, bounds.w - 4) });
  }
}

plugins.dispose("chat");
plugins.use({
  name: "roomy-chat",
  apply(ctx) {
    ctx.provide("chat", {
      bindTo: (block) => ({
        create: (session = new Session()) => new RoomyChat(session),
        labels: (entries) => block.effect(() => registerLabels(entries)),
      }),
    });
  },
});
```

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
