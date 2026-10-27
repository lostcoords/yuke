// The media of `run` and `call`: the host stores each media item of an event, and gives back each item with its bytes.

import { writeFile } from "yuke:fs";
import type { PluginSession } from "yuke:plugins";
import { assert, createHost, equal, folder, type TestMedia, test } from "yuke:test";

const call = { id: "c1", name: "shot", arguments: {} };

/** The plain values of `media`, for a comparison. */
function plain(media: readonly TestMedia[]): unknown[] {
  return media.map((item) => [item.mimeType, item.size, [...item.bytes]]);
}

test("tool.after gets the media of the result and gives back the kept and the new media with their bytes", async () => {
  const seen: unknown[] = [];
  const swap: PluginSession = (s) => {
    s.hook("tool.after", (event) => {
      seen.push(...event.result.media.map((item) => ("id" in item ? [item.mimeType, item.size] : item)));
      const first = event.result.media[0];
      if (first === undefined || !("id" in first)) return undefined;
      return { media: [{ id: first.id }, { mimeType: "image/gif", bytes: new Uint8Array([9, 8]) }] };
    });
  };
  await using host = await createHost({ plugins: [{ name: "swap", session: swap }] });
  const session = await host.openSession();
  await writeFile(`${folder()}/b.png`, new Uint8Array([4, 5]));

  const result = await session.run("tool.after", {
    call,
    result: {
      text: "two shots",
      isError: false,
      media: [
        { mimeType: "image/png", bytes: new Uint8Array([1, 2, 3]) },
        { mimeType: "image/png", path: "b.png" },
      ],
    },
  });

  equal(seen, [
    ["image/png", 3],
    ["image/png", 2],
  ]);
  equal(plain(result.media), [
    ["image/png", 3, [1, 2, 3]],
    ["image/gif", 2, [9, 8]],
  ]);
});

test("input.before gets media blocks in order and gives back a replacement with its media bytes", async () => {
  const kinds: string[] = [];
  const caption: PluginSession = (s) => {
    s.hook("input.before", (event) => {
      kinds.push(...event.blocks.map((block) => Object.keys(block)[0] ?? ""));
      return {
        replace: { blocks: [{ user_text: "an image" }, { mimeType: "image/png", bytes: new Uint8Array([7]) }] },
      };
    });
  };
  await using host = await createHost({ plugins: [{ name: "caption", session: caption }] });
  const session = await host.openSession();
  await writeFile(`${folder()}/c.png`, new Uint8Array([2]));

  const result = await session.run("input.before", {
    source: { kind: "user" },
    kind: "message",
    blocks: [
      { mimeType: "image/png", bytes: new Uint8Array([1]) },
      { user_text: "look" },
      { mimeType: "image/png", path: "c.png" },
    ],
  });

  equal(kinds, ["media", "user_text", "media"]);
  assert(typeof result === "object", "the input was not replaced");
  const [text, image] = result.replace.blocks;
  equal(text, { user_text: "an image" });
  assert(image !== undefined && "bytes" in image, "the second block is no media");
  equal(plain([image]), [["image/png", 1, [7]]]);
});

test("call gives back the media of the tool with their bytes", async () => {
  const shot: PluginSession = (s) => {
    s.tools.define({
      name: "shot",
      description: "Take a shot.",
      concurrency: "serial",
      parameters: { type: "object", properties: {} },
      execute: () => ({ text: "", media: [{ mimeType: "image/png", bytes: new Uint8Array([3, 1]) }] }),
    });
  };
  await using host = await createHost({ plugins: [{ name: "shot", session: shot }] });
  const session = await host.openSession();

  const result = await session.call("shot", {});

  equal(plain(result.media), [["image/png", 2, [3, 1]]]);
});
