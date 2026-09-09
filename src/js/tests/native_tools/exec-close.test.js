import { exec } from "yuke:exec";
globalThis.closed = 0;
exec("sleep 30 & child=$!; trap 'wait \"$child\"; exit 0' TERM; echo $$ $child > started; wait \"$child\"").catch(() => exec("echo late").catch(() => { globalThis.closed = 1; }));
