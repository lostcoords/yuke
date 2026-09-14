import "yuke:builtins";
import { client } from "yuke:client";

// The engine is absent here, so the put answers by extension and records the path the tool anchored.
globalThis.putPath = "";
client.blobPut = async (path) => {
  globalThis.putPath = path;
  if (path.endsWith(".png")) return { hash: "a".repeat(64), mime: "image/png", bytes: 67 };
  throw new Error("the blob file is not a PNG, JPEG, GIF, or WebP image");
};
