import { fetch, plugins } from "yuke";
import { equal } from "yuke:test";

const options = () => httpMode === "upload_stall" ? { method: "POST", body: "x".repeat(16 * 1024 * 1024) } : {};
const outcome = signal => fetch(httpUrl, { ...options(), signal }).then(response => {
  const read = response.text();
  globalThis.httpReadStarted = true;
  return read;
}).then(() => "unexpected success", error => error.message);
const finish = promise => promise.then(() => { globalThis.httpDone = true; }, error => { globalThis.httpError = error.message + "\n" + error.stack; globalThis.httpDone = true; });

async function run() {
  if (httpCleanup === "host" || httpCleanup === "body") {
    equal(await outcome(), "the request was canceled");
    if (httpCleanup === "host") equal(await outcome(), "the host is closed");
    return;
  }
  let request, signal;
  const owner = plugins.use({ name: "http-owner", apply(ctx) {
    signal = ctx.signal;
    request = outcome(signal);
  } });
  await new Promise(resolve => { globalThis.resumeHttp = resolve; });
  await owner.dispose();
  equal(signal.aborted, true);
  equal(await request, "the request was canceled");
  equal(await outcome(signal), "the operation was canceled");
}

if (httpCleanup === "tool") {
  plugins.use({ name: "http-tool", apply(ctx) {
    ctx.tools.define({ name: "fetch_probe", description: "Fetch a response.", parameters: { type: "object", properties: {} }, execute(_, signal) {
      return finish(outcome(signal).then(message => equal(message, "the request was canceled")));
    } });
  } });
} else finish(run());
