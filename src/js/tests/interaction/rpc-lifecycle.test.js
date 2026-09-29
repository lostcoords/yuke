import { equal } from "yuke:internal/test";
import { Context, Scope, plugins, scopeOf } from "yuke:internal/ext";
import { rpcInteractionPlugin } from "yuke:internal/interaction";
import { notifications } from "yuke:internal/kernel";

const ctx = new Context(new Scope("rpc-owner"), "rpc-owner");
const frontend = plugins.use(rpcInteractionPlugin);
const prompt = ctx.interaction.confirm("Pending RPC");
equal(ctx.interaction.pending, 1);
await frontend.dispose();
equal(ctx.interaction.pending, 0);
equal(await prompt, undefined);

const before = notifications.length;
plugins.use(rpcInteractionPlugin);
const events = [];
ctx.on("interaction.changed", (...args) => {
  equal(args.length, 0);
  events.push(ctx.interaction.pending);
});
let complete;
const outcome = new Promise(resolve => { complete = resolve; });
const login = ctx.interaction.deviceLogin({ login_id: "id", verification_url: "https://example.com", user_code: "code" }, outcome);
equal(ctx.interaction.pending, 1);
// The RPC frontend tells the client where to sign in. The forwarder sends the entry on the wire.
equal(notifications.length - before, 1);
equal(notifications[notifications.length - 1]?.message.startsWith("Sign in at https://example.com"), true);
complete({ type: "succeeded" });
equal((await login).type, "succeeded");
equal(ctx.interaction.pending, 0);
equal(events.join(), "1,0");
scopeOf(ctx).dispose();
