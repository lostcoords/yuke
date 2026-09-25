import { openSessionFinder } from "yuke:internal/defaults";
import { root } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
globalThis.root = root;
plugins.use({ name: "finder-test", apply(ctx) { ctx.inject(["tui"], (ctx) => { openSessionFinder(ctx); }); } });
