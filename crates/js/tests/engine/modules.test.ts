// The built-in modules that a module imports by name.

import { assert, equal, rejects, test } from "yuke:test";

test("a user module imports a public built-in module", async () => {
  const plugins = await import("yuke:plugins");
  equal(typeof plugins, "object");
});

test("an unknown built-in name does not load", async () => {
  const name: string = "yuke:nothing";
  const error = await rejects(import(name));
  assert(error instanceof TypeError);
  assert(error.message.includes("no built-in module has the name 'yuke:nothing'"), error.message);
});
