import { advice } from "yuke:ext";

/** @import { AdviceWhere, AdviceFunction, Disposer } from "../app/types/ext.js" */
let batch = 1000;
let phase = "", count = 0, calls = 0, hits = 0, sum = 0, steps = 0;
/** @type {Disposer[]} */
let disposers = [];
const target = {
  bias: 7,
  /** @param {number} a @param {number} b @param {number} c @returns {number} */
  method(a, b, c) { calls++; return this.bias + a + b + c; },
};
const original = target.method;
/** @type {Record<string, [AdviceWhere, AdviceFunction][]>} */
const handlers = {
  advice_direct: [],
  advice_before: [["before", () => { hits++; }]],
  advice_around: [["around", (next, a, b, c) => { hits++; return next(a, b, c); }]],
  advice_mixed: [
    ["filterArgs", (args) => { hits++; return args; }],
    ["before", () => { hits++; }],
    ["around", (next, a, b, c) => { hits++; return next(a, b, c); }],
    ["filterReturn", (value) => { hits++; return value; }],
    ["after", () => { hits++; }],
  ],
  advice_churn: [["around", (next, a, b, c) => next(a, b, c)]],
};

function install() {
  for (let i = 0; i < count; i++) {
    for (const [where, fn] of handlers[phase] || []) disposers.push(advice.advise(target, "method", where, fn));
  }
}

function remove() {
  for (let i = disposers.length - 1; i >= 0; i--) /** @type {Disposer} */ (disposers[i])();
  disposers.length = 0;
}

/** @param {string} name @param {number} scale @param {number} [batchSize] @returns {number} */
function start(name, scale, batchSize = 1000) {
  remove();
  if (!(name in handlers) || scale < 1 || !Number.isSafeInteger(batchSize) || batchSize < 1) throw new Error("invalid advice scenario");
  phase = name;
  count = scale;
  batch = batchSize;
  if (phase !== "advice_churn") install();
  step();
  calls = hits = sum = steps = 0;
  return batch;
}

function step() {
  if (phase === "advice_churn") {
    for (let i = 0; i < batch; i++) { install(); remove(); }
  } else {
    for (let i = 0; i < batch; i++) sum += target.method(i, 2, 3);
  }
  steps++;
  return batch;
}

function verify() {
  if (phase === "advice_churn") {
    if (target.method !== original || advice.list(target).length !== 0 || calls !== 0 || hits !== 0) throw new Error("advice teardown changed");
    return steps * batch;
  }
  const expected = steps * (batch * 12 + batch * (batch - 1) / 2);
  const handlerCount = count * (handlers[phase] || []).length;
  if (calls !== steps * batch || hits !== calls * handlerCount || sum !== expected) throw new Error("advice call changed");
  return sum;
}

globalThis.bench = { start, step, verify };
