import { fs } from "yuke:fs";
globalThis.ran = 0;
fs.readFile("a.txt").then(() => { globalThis.ran = 1; throw new Error("boom"); });
