import "yuke:builtins";
import { client } from "yuke:client";

// The engine is absent here, so the stub records the anchored path and answers one image.
globalThis.putPath = "";
client.blobPut = async (path) => {
  globalThis.putPath = path;
  return { hash: "a".repeat(64), mime: "image/png", bytes: 67 };
};
