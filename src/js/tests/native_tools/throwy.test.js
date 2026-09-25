import { fs } from "yuke:internal/native/fs";
globalThis.ran = 0;
fs.readFile("a.txt").then(() => { globalThis.ran = 1; throw new Error("boom"); });
