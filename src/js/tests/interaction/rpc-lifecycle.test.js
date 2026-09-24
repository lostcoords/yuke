import { equal } from "yuke:test";
import { Context, Scope, plugins, scopeOf } from "yuke:ext";
import { rpcInteractionPlugin } from "yuke:interaction";
import { native } from "yuke:interaction-native";

const ctx = new Context(new Scope("rpc-owner"), "rpc-owner");
const frontend = plugins.use(rpcInteractionPlugin);
const prompt = ctx.interaction.confirm("Pending RPC");
equal(ctx.interaction.pending, 1);
await frontend.dispose();
equal(ctx.interaction.pending, 0);
equal(await prompt, undefined);

const notices = [];
native.notify = (owner, message, level) => notices.push({ owner, message, level });
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
equal(notices.length, 1);
complete({ type: "succeeded" });
equal((await login).type, "succeeded");
equal(ctx.interaction.pending, 0);
equal(events.join(), "1,0");
scopeOf(ctx).dispose();
