import { check, equal } from "yuke:internal/test";
import { create, cancel } from "yuke:internal/native/cancellation";
import { Context, Scope, plugins, scopeOf } from "yuke:internal/ext";
import { root } from "yuke:internal/core";
import { tuiPlugin } from "yuke:internal/tui";
import { tuiInteractionPlugin } from "yuke:internal/interaction-ui";

plugins.use(tuiPlugin);
plugins.use(tuiInteractionPlugin);
const a = new Context(new Scope("a"), "a");
const b = new Context(new Scope("b"), "b");
const first = a.interaction.input("First");
const second = b.interaction.select("Second", ["one", "two"]);
equal(a.interaction.pending, 2);
equal(root.overlays.length, 2);
scopeOf(a).dispose();
equal(a.interaction.pending, 1);
equal(root.overlays.length, 1);
equal(await first, undefined);
plugins.dispose("tui-interaction");
equal(a.interaction.pending, 0);
equal(root.overlays.length, 0);
equal(await second, undefined);

plugins.use(tuiInteractionPlugin);
const failedOutcome = Promise.reject(new Error("device failed"));
let failure;
try {
  await b.interaction.deviceLogin({ login_id: "id", verification_url: "https://example.com", user_code: "secret" }, failedOutcome);
} catch (e) { failure = e; }
equal(failure.message, "device failed");
equal(b.interaction.pending, 0);
equal(root.overlays.length, 0);

const before = root.overlays.length;
// Any signal can cancel an interaction, not only a tool-call signal.
const signal = create();
const live = b.interaction.confirm("Live", "", { signal });
equal(root.overlays.length, before + 1);
cancel(signal);
equal(await live, undefined);
equal(root.overlays.length, before);
equal(b.interaction.pending, 0);

let finish;
const outcome = new Promise(resolve => { finish = resolve; });
const login = b.interaction.deviceLogin({ login_id: "id", verification_url: "https://example.com", user_code: "secret" }, outcome);
equal(b.interaction.pending, 1);
scopeOf(b).dispose();
equal(await login, undefined);
finish({ type: "succeeded" });
await Promise.resolve();
equal(b.interaction.pending, 0);
check("the device dialog is closed", root.overlays.length === 0);
