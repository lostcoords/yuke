// The bundled plugin `chat` on the sessions of a test host: the transcript of a pane, live and after a reload.

import { apply as chat } from "yuke:internal/bundled/chat";
import type { PluginSession, Sessions } from "yuke:plugins";
import { createFrame, createHost, equal, type FrameTest, reply, test } from "yuke:test";
import { waitFor } from "../wait.ts";

/** A plugin whose session defines the tool `greet`, which answers `hello` and its argument. */
const greeter: PluginSession = (s) => {
  s.tools.define({
    name: "greet",
    description: "Greet someone.",
    concurrency: "serial",
    parameters: { type: "object", properties: { who: { type: "string" } }, required: ["who"] },
    execute: (args) => `hello ${args.who}`,
  });
};

/** A frame with a chat pane on the session `id` of `sessions`. */
function chatFrame(sessions: Sessions, id: string): FrameTest {
  const frame = createFrame({ width: 30, height: 14 }, undefined, { cwd: "/w", session: id });
  const surface = frame.surface("chat");
  chat({ get: (name: string) => (name === "tui" ? surface.tui : sessions), options: {}, notify() {} } as never);
  frame.start();
  return frame;
}

function rows(frame: FrameTest): string[] {
  return frame.frame.cells.map((row) =>
    row
      .map((cell) => cell.text || " ")
      .join("")
      .trimEnd(),
  );
}

test("a pane draws the same transcript live and after a reload", async () => {
  let sessions: Sessions | undefined;
  await using host = await createHost({
    plugins: [
      {
        name: "keeper",
        apply: (ctx) => {
          sessions = ctx.get("sessions");
          return undefined;
        },
      },
      { name: "greeter", session: greeter },
    ],
    replies: [reply.toolCall("greet", { who: "Ada" }), reply.text("**Done**.")],
  });
  const session = await host.openSession();
  const service = sessions as Sessions;
  using live = chatFrame(service, session.id);
  await session.send("Greet Ada.");
  // Each pane opens its session in the background, so its rows come after its own open.
  const shows = (frame: FrameTest) => (): boolean => {
    frame.draw();
    return rows(frame).includes(" Done.");
  };
  await waitFor(shows(live));
  using reloaded = chatFrame(service, session.id);
  await waitFor(shows(reloaded));
  equal(rows(live), [
    "",
    " Greet Ada.",
    "",
    " greet",
    " hello Ada",
    "",
    " Done.",
    "",
    "",
    "",
    "",
    "",
    "──────────────────────────────",
    "Message…",
  ]);
  equal(rows(reloaded), rows(live));
});
