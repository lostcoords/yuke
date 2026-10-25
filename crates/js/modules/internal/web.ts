import { console } from "yuke:internal/console";
import * as encoding from "yuke:internal/encoding";
import * as events from "yuke:internal/events";
import * as streams from "yuke:internal/streams";
import * as url from "yuke:internal/url";

const {
  FinalizationRegistry: EngineFinalizationRegistry,
  queueMicrotask: engineQueueMicrotask,
  reportError,
} = globalThis;

// The engine drops the throw of a finalization callback, so the callback reports its own throw, as on the web. The
// property key names the constructor, and the prototype of the engine stays, so a registry keeps its standard shape.
const ReportingFinalizationRegistry = {
  FinalizationRegistry: function (cleanup: unknown): object {
    if (new.target === undefined) throw new TypeError("FinalizationRegistry: the constructor needs new");
    if (typeof cleanup !== "function") throw new TypeError("FinalizationRegistry: the cleanup is no function");
    const report = (heldValue: unknown): void => {
      try {
        cleanup(heldValue);
      } catch (error) {
        reportError(error);
      }
    };
    return Reflect.construct(EngineFinalizationRegistry, [report], new.target);
  },
}.FinalizationRegistry as unknown as FinalizationRegistryConstructor;
Object.defineProperty(ReportingFinalizationRegistry, "prototype", {
  value: EngineFinalizationRegistry.prototype,
  writable: false,
});
Object.defineProperty(EngineFinalizationRegistry.prototype, "constructor", { value: ReportingFinalizationRegistry });

// The check against the global declarations keeps the classes and the declarations of the authors in step.
const classes = {
  AbortController: events.AbortController,
  AbortSignal: events.AbortSignal,
  CustomEvent: events.CustomEvent,
  Event: events.Event,
  EventTarget: events.EventTarget,
  FinalizationRegistry: ReportingFinalizationRegistry,
  ReadableStream: streams.ReadableStream,
  ReadableStreamDefaultController: streams.ReadableStreamDefaultController,
  ReadableStreamDefaultReader: streams.ReadableStreamDefaultReader,
  TextDecoder: encoding.TextDecoder,
  TextEncoder: encoding.TextEncoder,
  URL: url.URL,
  URLSearchParams: url.URLSearchParams,
} satisfies {
  AbortController: typeof AbortController;
  AbortSignal: typeof AbortSignal;
  CustomEvent: typeof CustomEvent;
  Event: typeof Event;
  EventTarget: typeof EventTarget;
  FinalizationRegistry: typeof FinalizationRegistry;
  ReadableStream: typeof ReadableStream;
  ReadableStreamDefaultController: typeof ReadableStreamDefaultController;
  ReadableStreamDefaultReader: typeof ReadableStreamDefaultReader;
  TextDecoder: typeof TextDecoder;
  TextEncoder: typeof TextEncoder;
  URL: typeof URL;
  URLSearchParams: typeof URLSearchParams;
};

// The engine gives a monotonic `now`, and the web needs `timeOrigin` as epoch time, so this object adapts the clock.
const engineNow = globalThis.performance.now.bind(globalThis.performance);
const timeOrigin = Date.now() - engineNow();
const performance: typeof globalThis.performance = Object.freeze({
  timeOrigin,
  now: (): number => engineNow(),
  toJSON: () => ({ timeOrigin }),
});

// The engine drops the throw of a queued callback, so the callback reports its own throw, as on the web.
function queueMicrotask(callback: () => void): void {
  if (typeof callback !== "function") throw new TypeError("queueMicrotask: the callback is no function");
  engineQueueMicrotask(() => {
    try {
      callback();
    } catch (error) {
      reportError(error);
    }
  });
}

const objects = { console, performance, queueMicrotask } satisfies {
  console: typeof globalThis.console;
  performance: typeof globalThis.performance;
  queueMicrotask: typeof globalThis.queueMicrotask;
};

// Web IDL gives each global a property that a script can replace: writable, configurable, and not enumerable.
for (const [name, value] of Object.entries({ ...classes, ...objects })) {
  Object.defineProperty(globalThis, name, { value, writable: true, enumerable: false, configurable: true });
}
