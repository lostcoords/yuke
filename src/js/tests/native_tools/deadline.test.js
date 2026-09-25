import { exec } from "yuke:internal/native/exec";
globalThis.result = "pending";
exec("sleep 30", { timeoutMs: 300 }).then((r) => {
  globalThis.result = r.timedOut && r.code === null && r.signal === null ? "ok" : "wrong";
});
