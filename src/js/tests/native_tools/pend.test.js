import { fs } from "yuke:fs";
globalThis.settled = 0;
fs.readFile("a.txt").then(() => { globalThis.settled = 1; });
