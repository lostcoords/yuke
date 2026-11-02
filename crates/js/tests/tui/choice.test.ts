// The saved model pick is ready after load and stays in step with its file after save.

import { readTextFile, writeTextFile } from "yuke:fs";
import { SavedChoice } from "yuke:internal/bundled/chat/choice";
import { equal, folder, test } from "yuke:test";

test("load returns the saved pick and save updates the file and current pick", async () => {
  await writeTextFile("choice.json", '{"model":{"provider":"p","model":"m"},"reasoning":"off"}', {
    baseDir: folder(),
  });
  const errors: unknown[] = [];
  const saved = await SavedChoice.load(folder(), (error) => errors.push(error));
  equal(saved.current, { model: { provider: "p", model: "m" }, reasoning: "off" });

  await saved.save({ model: { provider: "p", model: "n" }, reasoning: "low" });

  equal(
    [saved.current, JSON.parse(await readTextFile("choice.json", { baseDir: folder() })), errors],
    [
      { model: { provider: "p", model: "n" }, reasoning: "low" },
      { model: { provider: "p", model: "n" }, reasoning: "low" },
      [],
    ],
  );
});
