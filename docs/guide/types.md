---
description: Use the installed public modules and declarations to type-check yuke plugins.
---

# Public types

Use the public library files of the installed yuke release as the API reference. They define exact signatures, unions, optional values, and errors. Match the source release to `yuke --version` when you inspect implementation code.

Yuke plugins run in QuickJS. They do not run in Node.js or a browser. An API in a Node or browser declaration is not evidence that yuke supports it.

## Public modules

Import each API from its public module:

| Module | Main exports |
|---|---|
| `yuke:plugins` | `PluginContext`, `SessionContext`, `PluginApply`, `PluginSession`, `Services`, session handles, and hook types. |
| `yuke:tools` | `Tool`, `ToolContext`, `ObjectSchema`, and `Infer`. |
| `yuke:tui` | `Tui`, `View`, `TextEditor`, `TextView`, `Markdown`, `Picker`, and layout helpers. |
| `yuke:chat` | Chat blocks, `ChatService`, and `ChatPresentation`. |
| `yuke:transcript` | `Transcript` and its entry types. |
| `yuke:protocol` | Session, model, input, event, and other protocol records. |
| `yuke:fs` | File operations. |
| `yuke:process` | Process operations. |
| `yuke:net` | Network connections. |
| `yuke:ai` | Provider APIs. |
| `yuke:test` | Test assertions and host, model, and frame test helpers. |

There is no root `yuke` module. Do not import `yuke:internal/*`. Internal modules are not plugin extension points. The installed public library excludes them.

## Installed layout

The package holds the public library under `lib/yuke`:

```text
lib/yuke/
├── modules/
│   ├── plugins.ts
│   ├── tools.ts
│   └── ...
├── types/
│   ├── globals.d.ts
│   ├── tui.d.ts
│   ├── chat.d.ts
│   └── ...
├── protocol/bindings/
└── tsconfig.json
```

Some modules define their types directly in `modules/*.ts`. Host-backed modules use declarations in `types/*.d.ts`. The configuration includes the public declarations and maps `yuke:*` imports to the modules.

The installer creates a profile `tsconfig.json` that extends the installed library configuration. Keep its absolute `extends` path. Run `tsc -p` with that profile configuration. See [Your first plugin](first-plugin.md#4-check-the-types) to include JavaScript examples.

Use a TypeScript compiler that supports the `target`, libraries, and options in the installed configuration.

## Find a declaration

Search these files under the installed `lib/yuke` directory:

| Need | File and name |
|---|---|
| Plugin entry and cleanup | `modules/plugins.ts`: `PluginApply`, `PluginSession`, `Cleanup`. |
| Shared context | `modules/plugins.ts`: `PluginContext`. |
| Per-session tools and hooks | `modules/plugins.ts`: `SessionContext`, `SessionHooks`. |
| Host events | `modules/plugins.ts`: `HostEvents`. |
| Session access | `modules/plugins.ts`: `Sessions`, `SessionHandle`, `ViewEvent`. |
| Tool schemas and results | `modules/tools.ts`: `ObjectSchema`, `Infer`, `ToolResult`. |
| Commands, keys, status, mounts | `types/tui.d.ts`: `Tui`. |
| Views and text widgets | `types/tui.d.ts`: `View`, `TextEditor`, `TextView`. |
| Chat service and presentation | `types/chat.d.ts`: `ChatService`, `ChatPresentation`. |
| Transcript data | `types/transcript.d.ts`: `Transcript`, `Entry`. |
| Protocol records | `protocol/bindings/*.ts`. |
| Runtime globals | `types/globals.d.ts`. |
| Tests | `types/test.d.ts`. |

For example, run these commands from `lib/yuke`:

```sh
grep -n -A 45 'interface PluginContext' modules/plugins.ts
grep -n -A 45 'interface SessionContext' modules/plugins.ts
grep -n -A 45 'interface Tui' types/tui.d.ts
grep -n -A 45 'interface ChatService' types/chat.d.ts
```

If a name is absent from the public files, do not call it through a cast or `any`.

## Type a plugin entry

In TypeScript, import context types with `import type`:

<<< @/snippets/types/entry.ts

The entry functions return `undefined` or cleanup, directly or through a promise. An explicit `undefined` return also makes the function assignable to `PluginApply` or `PluginSession`.

For JavaScript, use JSDoc:

<<< @/snippets/types/entry.js

An inline callback gets its parameter types from the API call. Add a type annotation when a separate declaration needs one. Protocol records come from imports, not a global `Wire` namespace.

## Type plugin options

Export an `optionsSchema` from the entry. Use `Infer<typeof optionsSchema>` as the context's option type. `ObjectSchema` and `Infer` come from `yuke:tools`.

Use `as const satisfies ObjectSchema` for a separate TypeScript schema. It keeps literal property and required-field names for inference. See [Plugins](plugins.md) for options and [Tools](tools.md) for tool schemas.

## Declare a service

A shared service adds its name to `Services` in `yuke:plugins`. For example, place this in a `.d.ts` file that each consumer includes:

<<< @/snippets/types/service.d.ts

The provider declares the name in its manifest `provides`. A consumer declares it in `uses`. The loader then starts the provider first. `ctx.provide("example.counter.v1", value)` and `ctx.get("example.counter.v1")` check the declared shape. An undeclared service name fails the type check.

The built-in services `tui`, `sessions`, `catalog`, and `plugins` need no `uses` entry. `tui` can be `undefined`. The `chat` service comes from the bundled chat plugin and needs `uses`.

## Events and client messages

`ctx.on` listens to the facts in `HostEvents`, such as `session.opened` and `theme.changed`. It is not a custom event bus.

`ctx.emit` and `session.emit` send extension events to the active RPC client. `session.request` sends an extension request and waits for the client response. They do not call `ctx.on` listeners. Keep custom in-process notifications inside a declared service.
