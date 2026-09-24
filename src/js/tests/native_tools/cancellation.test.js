import { check, equal } from "yuke:test";
import { create, cancel, drain } from "yuke:cancellation-native";
import { exec } from "yuke:exec";

const token = create();
let invalid = 0;
for (const action of [
  () => cancel({ aborted: false }),
  () => drain(token),
  () => { token.aborted = true; },
  () => Object.defineProperty(token, "aborted", { value: true }),
]) {
  try { action(); } catch { invalid += 1; }
}
equal(invalid, 4);
check("the signal remains active", !token.aborted);
cancel(token);
cancel(token);
check("cancel is idempotent", token.aborted);

const signal = create();
const survivor = create();
const outcomes = [];
const stopped = exec("sleep 30 & child=$!; trap 'wait \"$child\"; exit 0' TERM; echo $$ $child > started; wait \"$child\"", { signal }).then(
  () => { throw new Error("the owned command must cancel"); },
  (error) => { outcomes.push(error.code); },
);
const alsoStopped = exec("sleep 30", { signal }).then(
  () => { throw new Error("every command on the signal must cancel"); },
  (error) => { outcomes.push(error.code); },
);
const kept = exec("printf survivor", { signal: survivor }).then(result => {
  equal(result.stdout, "survivor");
});
function cancelCommand() {
  cancel(signal);
  cancel(signal);
  const drained = drain(signal);
  equal(drained, drain(signal));
  return drained.then(() => {
    equal(outcomes.join(","), "CANCELED,CANCELED");
    return exec("touch forbidden", { signal }).then(
      () => { throw new Error("a canceled signal must refuse new work"); },
      (error) => equal(error.code, "CANCELED"),
    );
  });
}
globalThis.cancellationDone = false;
globalThis.finishCancellation = async () => {
  await cancelCommand();
  await Promise.all([stopped, alsoStopped, kept]);
  cancel(survivor);
  await drain(survivor);
  check("signals stay canceled", signal.aborted);
  globalThis.cancellationDone = true;
};
