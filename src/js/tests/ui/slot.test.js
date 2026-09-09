import { check } from "yuke:test";
import { slot, events } from "yuke:core";
class Base { label() { return slot.get(this, "label") ?? "base"; } }
class Sub extends Base {}
const b = new Base();
const sub = new Sub();

check("default", b.label() === "base");
const d1 = slot.add(Base, "label", () => "one");
check("supplied", b.label() === "one");
// A subclass reads the slot its base class declares.
check("subclass", sub.label() === "one");

const d2 = slot.add(Base, "label", () => "two");
check("newest-wins", b.label() === "two");

// A null answer passes the slot on rather than claiming it.
const d3 = slot.add(Base, "label", () => null);
check("declines", b.label() === "two");
d3();

// A disposer uncovers the provider it hid.
d2();
check("uncovered", b.label() === "one");
d1();
check("restored", b.label() === "base");

// The provider reads the instance, so one class can answer differently per object.
const d4 = slot.add(Base, "label", (obj) => (obj === sub ? "sub" : null));
check("per-instance", sub.label() === "sub" && b.label() === "base");
d4();

// A provider that disposes itself must not hide the provider behind it.
const d7 = slot.add(Base, "label", () => "older");
let d8;
d8 = slot.add(Base, "label", () => { d8(); return null; });
check("self-dispose-keeps-next", b.label() === "older");
d7();

// A subclass provider wins before a base provider, whatever the registration order.
const dBase = slot.add(Base, "label", () => "from-base");
const dSub = slot.add(Sub, "label", () => "from-sub");
check("subclass-outranks-base", sub.label() === "from-sub" && b.label() === "from-base");
dSub();
check("subclass-falls-back", sub.label() === "from-base");
dBase();

// A throwing provider is reported and skipped, so the frame survives it.
let errs = 0;
const offErr = events.on("ext.error", () => { errs++; });
const d5 = slot.add(Base, "label", () => { throw new Error("bad"); });
const d6 = slot.add(Base, "label", () => null);
check("throw-skipped", b.label() === "base" && errs === 1);
d5();
d6();
offErr();

// The last disposer leaves no registration behind.
check("no-residue", !slot._map.has(Base.prototype) && !slot._map.has(Sub.prototype));

let threw = 0;
try { slot.add({}, "x", () => 1); } catch (e) { if (e instanceof TypeError) threw++; }
try { slot.add(Base, "x", 1); } catch (e) { if (e instanceof TypeError) threw++; }
check("reject", threw === 2 && b.label() === "base");
