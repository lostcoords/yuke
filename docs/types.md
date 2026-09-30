# Types

`yuke.d.ts` in the profile declares the public API. Each export has a summary, and a tag text tells what `null` means, the units, and when a call throws. The file is large, so search it: `grep -n 'currentPane' yuke.d.ts`, and read the lines around the match.

The `declare module "yuke..."` blocks at the top map each export to its definition, for example `export import currentPane = $session.currentPane;`. Search `declare namespace $session` for the body.

## Editor

`jsconfig.json` in the profile extends `yuke.jsconfig.json`, so an editor checks `index.js` with the options of this release. The options are strict: a parameter with no type is an error. A callback written inline in a call gets its types from the call. A callback that you declare apart needs a type: `/** @type {import("yuke:chat").Render} */`, `/** @type {import("yuke").ToolDefinition} */`, or `@param`. The engine wire types are in the global `Wire` namespace, for example `Wire.Session`. Put a JSDoc comment on its own line above a property: a comment on the line of the `{` does not attach, and the property becomes `any`.

## Your own events

A plugin names its own events `<plugin>:<name>`. To type one, add a `.d.ts` file next to `index.js`:

```ts
declare module "yuke" {
  interface Events {
    "my-plugin:ping"(count: number): void;
  }
}
export {};
```

Then `ctx.on("my-plugin:ping", …)` and `events.emit("my-plugin:ping", …)` check their arguments. An event without a declaration takes any arguments.

## Your own capabilities

```ts
declare module "yuke" {
  interface Capabilities {
    counter: { count(): number };
  }
}
export {};
```

Then `ctx.provide("counter", …)` checks the value, and `ctx.inject(["counter"], (c) => …)` types `c.counter`. A capability without a declaration is `unknown`.
