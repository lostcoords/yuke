import { equal } from "yuke:test";
import { client } from "yuke:client";
const surface = ["request", "sessionList", "sessionOpen", "sessionClose",
  "sessionOutline", "sessionParts", "sessionPart", "partTextPage",
  "textContent", "sessionSendInput", "sessionCancelRun", "sessionCreate", "catalogList", "catalogReload",
  "authLogin", "authCancelLogin", "authSetApiKey", "authRemove"]
  .every((k) => typeof client[k] === "function");
// No engine is attached in a unit test, so a view read answers its empty projection.
const closed = client.sessionOutline("00".repeat(16)) === null;
equal(surface && closed ? "ok" : "fail", "ok");
