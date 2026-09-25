import { check, equal } from "yuke:test";
import { Context, Scope, interaction, scopeOf } from "yuke:ext";
import { events } from "yuke:kernel";

const owner = () => new Context(new Scope("interaction-test"), "same-name");
const a = owner(), b = owner();
const shown = [];
let closed = 0;
const answerer = {
  interactive: true,
  open(request, ctx, options, resolve, reject) {
    shown.push({ request, resolve, reject });
    return () => { closed++; };
  },
  notify() {},
};
const uninstall = interaction.install(answerer);
const changes = [];
const observer = owner();
observer.on("interaction.changed", () => changes.push(observer.interaction.pending));
const surface = a.interaction;
let readonly;
try { surface.pending = 9; } catch (error) { readonly = error; }
check("pending is read-only", readonly instanceof TypeError);
const first = surface.confirm("First");
const second = b.interaction.input("Secret", "", { secret: true });
equal(surface.pending, 2);
equal(owner().interaction.pending, 2);
equal(changes.join(), "1,2");
shown[1].resolve("private");
equal(surface.pending, 1);
equal(await second, "private");
scopeOf(a).dispose();
equal(surface.pending, 0);
equal(await first, undefined);
equal(closed, 2);
shown[0].resolve(true);
equal(changes.join(), "1,2,1,0");
equal(await surface.confirm("Disposed"), undefined);
equal(shown.length, 2);

// Each registration owns its requests, even with the same answerer object.
const old = b.interaction.confirm("Old");
const removeNew = interaction.install(answerer);
const newer = b.interaction.confirm("New");
uninstall();
equal(b.interaction.pending, 1);
equal(await old, undefined);
shown[3].resolve(true);
equal(await newer, true);
removeNew();

// Validation and immediate denial create no wait state.
const denied = interaction.install({ interactive: false, notify() {} });
const before = changes.length;
equal(await b.interaction.confirm("Denied"), false);
equal(await b.interaction.input("Denied"), undefined);
for (const ask of [() => b.interaction.confirm(""), () => b.interaction.select("Bad", ["x", "x"]), () => b.interaction.input(12), () => b.interaction.confirm("Bad", "", { signal: { aborted: false } }), () => b.interaction.confirm("Bad", "", null)]) {
  let error;
  try { await ask(); } catch (e) { error = e; }
  check("invalid requests reject", error instanceof TypeError);
}
equal(changes.length, before);
denied();
let unavailable;
try { await b.interaction.confirm("No frontend"); } catch (e) { unavailable = e; }
equal(unavailable.name, "InteractionUnavailable");
equal(changes.length, before);

// Synchronous completion and open failure leave no request or scope effect.
const effects = scopeOf(b).disposers.length;
for (const fail of [false, true]) {
  const remove = interaction.install({ ...answerer, open(request, ctx, options, resolve) {
    if (fail) throw new Error("open failed");
    resolve(true);
    return () => { closed++; };
  } });
  let error;
  try { equal(await b.interaction.confirm("Immediate"), true); } catch (e) { error = e; }
  equal(error?.message, fail ? "open failed" : undefined);
  equal(b.interaction.pending, 0);
  equal(scopeOf(b).disposers.length, effects);
  remove();
}
equal(changes.length, before);

// A change listener can dispose the requester during admission.
const remove = interaction.install(answerer);
const reentrant = owner();
const off = events.on("interaction.changed", () => {
  if (b.interaction.pending > 0) scopeOf(reentrant).dispose();
});
equal(await reentrant.interaction.confirm("Reentrant"), undefined);
equal(b.interaction.pending, 0);
off();

// A listener fault cannot retain a request, and rejection removes it before the caller resumes.
const offFault = events.on("interaction.changed", () => { throw new Error("listener failed"); });
const failed = b.interaction.confirm("Failure");
shown[shown.length - 1].reject(new Error("request failed"));
equal(b.interaction.pending, 0);
let failure;
try { await failed; } catch (e) { failure = e; }
equal(failure.message, "request failed");
offFault();
remove();
const observed = changes.length;
scopeOf(observer).dispose();
scopeOf(b).dispose();
equal(surface.pending, 0);

// A disposer fault rejects its request and does not stop the frontend sweep.
const c = owner();
let cleanupCalls = 0;
const broken = interaction.install({ ...answerer, open() {
  return () => { cleanupCalls++; throw new Error("close failed"); };
} });
const results = Promise.allSettled([c.interaction.confirm("One"), c.interaction.confirm("Two")]);
broken();
equal(c.interaction.pending, 0);
equal(cleanupCalls, 2);
check("both requests reject", (await results).every(result => result.status === "rejected" && result.reason.message === "close failed"));
scopeOf(c).dispose();

// Disposal inside open closes its returned resource without a transient count.
const duringOpen = owner();
let closeCalls = 0;
const removeDuringOpen = interaction.install({ ...answerer, open() {
  scopeOf(duringOpen).dispose();
  return () => { closeCalls++; };
} });
equal(await duringOpen.interaction.confirm("During open"), undefined);
equal(duringOpen.interaction.pending, 0);
equal(closeCalls, 1);
removeDuringOpen();

equal(changes.length, observed);

// Setup errors take precedence over an answer before open returns.
const invalidOpen = owner();
const removeInvalid = interaction.install({ ...answerer, open(request, ctx, options, resolve) {
  resolve(true);
  throw new Error("setup failed after answer");
} });
let setupError;
try { await invalidOpen.interaction.confirm("Invalid open"); } catch (error) { setupError = error; }
equal(setupError.message, "setup failed after answer");
equal(invalidOpen.interaction.pending, 0);
equal(scopeOf(invalidOpen).disposers.length, 0);
removeInvalid();
scopeOf(invalidOpen).dispose();
