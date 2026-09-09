import { check } from "yuke:test";
import { Scope } from "yuke:ext";

// A scope reverts its effects newest first.
{
  const order = [];
  const s = new Scope("t");
  s.effect(() => { order.push("a-set"); return () => order.push("a"); });
  s.effect(() => { order.push("b-set"); return () => order.push("b"); });
  s.effect(() => { order.push("c-set"); return () => order.push("c"); });
  s.dispose();
  check("lifo", order.join(",") === "a-set,b-set,c-set,c,b,a");
}

// A disposer cleans up once, by hand or through dispose.
{
  let n = 0;
  const s = new Scope("t2");
  const off = s.effect(() => () => n++);
  off(); off();
  s.dispose();
  check("effect-idempotent", n === 1);
}

// A child scope disposes with its parent, newest first.
{
  const order = [];
  const parent = new Scope("p");
  parent.effect(() => () => order.push("parent"));
  const kid = parent.child("kid");
  kid.effect(() => () => order.push("kid"));
  parent.dispose();
  check("scope-child", order.join(",") === "kid,parent" && !kid.alive);
}

// A child disposal detaches its parent entry, so repeated unloads do not retain cleanup captures.
{
  const parent = new Scope("detach");
  const kid = parent.child("kid");
  check("child-entry-held", parent._disposers.length === 1);
  kid.dispose();
  check("child-entry-detached", parent._disposers.length === 0);
  const off = parent.effect(() => () => {});
  check("effect-entry-held", parent._disposers.length === 1);
  off();
  check("effect-entry-detached", parent._disposers.length === 0);
  parent.dispose();
}

// An effect on a disposed scope throws.
{
  const s = new Scope("dead");
  s.dispose();
  let threw = false;
  try { s.effect(() => {}); } catch (e) { threw = true; }
  check("scope-dead-effect", threw);
}
