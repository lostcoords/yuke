import * as events from "yuke:internal/events";

// The check against the global declarations keeps the classes and the declarations of the authors in step.
const classes = {
  AbortController: events.AbortController,
  AbortSignal: events.AbortSignal,
  CustomEvent: events.CustomEvent,
  Event: events.Event,
  EventTarget: events.EventTarget,
} satisfies {
  AbortController: typeof AbortController;
  AbortSignal: typeof AbortSignal;
  CustomEvent: typeof CustomEvent;
  Event: typeof Event;
  EventTarget: typeof EventTarget;
};

// Web IDL gives each class a global that a script can replace: writable, configurable, and not enumerable.
for (const [name, value] of Object.entries(classes)) {
  Object.defineProperty(globalThis, name, { value, writable: true, configurable: true });
}
