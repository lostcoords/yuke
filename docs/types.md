# Public types

`yuke.d.ts` declares the public API of the installed release. It is authoritative for exact names, signatures, unions, null values, and documented errors. Markdown explains how to combine those APIs. The examples show complete patterns.

## Find a declaration

Run these commands in the profile directory:

```sh
grep -n -A 40 -B 5 'interface EventsBase' yuke.d.ts
grep -n -A 40 -B 5 'HookPayloads' yuke.d.ts
grep -n -A 40 -B 5 'HookReplacements' yuke.d.ts
grep -n -A 40 -B 5 'class ChatView' yuke.d.ts
grep -n -A 40 -B 5 'class Session' yuke.d.ts
grep -n -A 40 -B 5 'class Transcript' yuke.d.ts
grep -n -A 40 -B 5 'class TextInput' yuke.d.ts
grep -n -A 40 -B 5 'declare namespace $session' yuke.d.ts
grep -n -A 40 -B 5 'declare namespace $client' yuke.d.ts
```

The `declare module "yuke..."` blocks at the top map each import to its definition. For example, `export import currentPane = $session.currentPane` points to `declare namespace $session`.

| Need | Search |
|---|---|
| event names and arguments | `interface EventsBase` |
| hook payloads and replacements | `HookPayloads`, `HookReplacements` |
| plugin lifecycle | `class Context`, `const plugins` |
| focused chat state | `declare namespace $session` |
| engine queries | `declare namespace $client` |
| model tools | `interface ToolDefinition` |
| commands, keys, and status | `class Surface`, `CommandSpec`, `KeyBinding` |
| MCP config | `ServerConfig`, `OAuthConfig`, `McpOptions` |
| subagent config | `AgentRow`, `AgentsOptions` |

If a name is absent, do not use it as a public API. Inspect the source only for an undocumented behavior or an implementation detail. Match the source tree to `yuke --version` when source inspection is necessary.

## Editor

`jsconfig.json` extends `yuke.jsconfig.json`, so the editor checks profile JavaScript with the strict options of this release. A callback written inline gets its parameter types from the call. A callback declared elsewhere needs JSDoc:

```js
/** @type {import("yuke:chat").Render} */
const render = {
  tools: { web_search: (args) => ({ verb: "search", subject: String(args.query), input: "" }) },
};
```

Other useful annotations include `import("yuke").ToolDefinition` and `@param`. Put a JSDoc comment above a property, not on the opening `{` line. The global `Wire` namespace contains engine wire types such as `Wire.Session`.

## Custom events

Add a `.d.ts` file next to `index.js`:

```ts
declare module "yuke" {
  interface Events {
    "my-plugin:ping"(count: number): void;
  }
}
export {};
```

Then `ctx.on("my-plugin:ping", ...)` and `events.emit("my-plugin:ping", ...)` check their arguments. A namespaced event without a declaration accepts any arguments.

## Custom capabilities

```ts
declare module "yuke" {
  interface Capabilities {
    counter: { count(): number };
  }
}
export {};
```

Then `ctx.provide("counter", value)` checks the value, and `ctx.inject(["counter"], (c) => ...)` types `c.counter`. An undeclared custom capability has type `unknown`.
