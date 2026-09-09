import { check } from "yuke:test";
import { plugins, services } from "yuke:ext";

const log = [];
plugins.use({
  name: "gated",
  apply(ctx) {
    log.push("apply");
    ctx.inject(["cap"], (c) => {
      log.push("in:" + c.cap);
      return () => log.push("out");
    });
  },
});
// The plugin applies now; only the injected block waits.
check("apply-ran", log.join(",") === "apply");
check("absent", !services.has("cap"));

const off1 = services.provide("cap", "T1");
check("activated", log.join(",") === "apply,in:T1");

// A second provider hides the first, so the block reads the new value.
// The new block builds before the old one leaves, so a shared resource passes across.
const off2 = services.provide("cap", "T2");
check("restacked", log.join(",") === "apply,in:T1,in:T2,out");

// The withdrawal of the live provider reveals the one below it.
off2();
check("revealed", log.join(",") === "apply,in:T1,in:T2,out,in:T1,out");

off1();
check("withdrawn", log.join(",") === "apply,in:T1,in:T2,out,in:T1,out,out");
check("gone", !services.has("cap"));
