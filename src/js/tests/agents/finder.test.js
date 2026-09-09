import { openSessionFinder } from "yuke:defaults";
import { root } from "yuke:core";
import { plugins } from "yuke:ext";
globalThis.root = root;
plugins.use({ name: "finder-test", apply(ctx) { ctx.inject(["tui"], (ctx) => { openSessionFinder(ctx); }); } });
