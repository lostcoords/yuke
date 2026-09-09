import { check } from "yuke:test";
import { events } from "yuke:core";
import { services } from "yuke:ext";

// A second provider hides the first; its withdrawal reveals the one below.
{
  const seen = [];
  const offEvt = events.on("service:stack", (v) => seen.push(v === undefined ? "none" : v));
  const offA = services.provide("stack", "a");
  check("service-first", services.get("stack") === "a");
  const offB = services.provide("stack", "b");
  const hid = services.get("stack") === "b";
  offB();
  const revealed = services.get("stack") === "a";
  offA();
  check("service-stack", hid && revealed && services.get("stack") === undefined);
  check("service-events", seen.join(",") === "a,b,a,none");
  offEvt();
}

// Two providers of one value stay apart, so a disposer withdraws its own registration.
{
  const same = { v: 1 };
  const offA = services.provide("dup", same);
  const offB = services.provide("dup", same);
  offB();
  const still = services.get("dup") === same;
  offB();
  const held = services.get("dup") === same;
  offA();
  check("service-identity", still && held && services.get("dup") === undefined);
}

// A provider disposed below the top leaves the live provider in place.
{
  const offA = services.provide("rev", "a");
  const offB = services.provide("rev", "b");
  offA();
  const live = services.get("rev") === "b";
  offB();
  check("service-reverse", live && services.get("rev") === undefined);
}
