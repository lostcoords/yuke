import { console } from "yuke:internal/console";
import { TextDecoder, TextEncoder } from "yuke:internal/encoding";
import * as events from "yuke:internal/events";

// The check against the global declarations keeps the classes and the declarations of the authors in step.
const classes = {
  AbortController: events.AbortController,
  AbortSignal: events.AbortSignal,
  CustomEvent: events.CustomEvent,
  Event: events.Event,
  EventTarget: events.EventTarget,
  TextDecoder,
  TextEncoder,
} satisfies {
  AbortController: typeof AbortController;
  AbortSignal: typeof AbortSignal;
  CustomEvent: typeof CustomEvent;
  Event: typeof Event;
  EventTarget: typeof EventTarget;
  TextDecoder: typeof TextDecoder;
  TextEncoder: typeof TextEncoder;
};

// The engine gives a monotonic `now`, and the web needs `timeOrigin` as epoch time, so this object adapts the clock.
const engineNow = globalThis.performance.now.bind(globalThis.performance);
const timeOrigin = Date.now() - engineNow();
const performance: typeof globalThis.performance = Object.freeze({
  timeOrigin,
  now: (): number => engineNow(),
  toJSON: () => ({ timeOrigin }),
});

const objects = { console, performance } satisfies {
  console: typeof globalThis.console;
  performance: typeof globalThis.performance;
};

// A hook of `Error.prepareStackTrace` gets the function of each stack frame, internal functions too. A data property
// in its place keeps the hook from the engine, and code that sets it still runs.
Object.defineProperty(Error, "prepareStackTrace", {
  value: undefined,
  writable: true,
  enumerable: false,
  configurable: false,
});

// Web IDL gives each global a property that a script can replace: writable, configurable, and not enumerable.
for (const [name, value] of Object.entries({ ...classes, ...objects })) {
  Object.defineProperty(globalThis, name, { value, writable: true, enumerable: false, configurable: true });
}
