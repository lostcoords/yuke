import { plugins } from "yuke:internal/ext";
import { builtins } from "yuke:internal/builtins";
import { client } from "yuke:internal/client";
plugins.use(builtins);

// The engine is absent here, so the stub records the anchored path and answers one image.
globalThis.putPath = "";
client.blobPut = async (path) => {
  globalThis.putPath = path;
  return { hash: "a".repeat(64), mime: "image/png", bytes: 67 };
};
