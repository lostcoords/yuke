/**
 * The web classes `Event`, `CustomEvent`, `EventTarget`, `AbortSignal`, and `AbortController` for targets without a
 * tree. `yuke:internal/web` installs them as globals.
 */
import { dictionary, domString, needs, PrivateMap, uncurryThis, webClass } from "yuke:internal/webidl";

// The classes keep the globals of the runtime start, so a plugin that replaces a global does not change them.
const { DOMException, reportError, setTimeout } = globalThis;
const now = globalThis.performance.now.bind(globalThis.performance);
// The signal graph keeps the `WeakRef` and `FinalizationRegistry` functions of the runtime start. A later patch of
// these globals or of their prototypes does not change the graph.
const StartWeakRef = WeakRef;
const deref = uncurryThis(WeakRef.prototype.deref) as (ref: WeakRef<AbortSignal>) => AbortSignal | undefined;
const register = uncurryThis(FinalizationRegistry.prototype.register);
const unregister = uncurryThis(FinalizationRegistry.prototype.unregister);

/** The longest delay of one timer. A longer timeout uses a chain of timers with this delay. */
const LONGEST_DELAY = 2 ** 31 - 1;

interface EventState {
  readonly type: string;
  readonly bubbles: boolean;
  readonly cancelable: boolean;
  readonly composed: boolean;
  readonly timeStamp: number;
  target: EventTarget | null;
  currentTarget: EventTarget | null;
  dispatching: boolean;
  trusted: boolean;
  canceled: boolean;
  /** A passive listener runs, so `preventDefault` has no effect. */
  passive: boolean;
  stopped: boolean;
  stoppedImmediately: boolean;
}

interface Listener {
  readonly type: string;
  readonly callback: EventListenerOrEventListenerObject;
  readonly capture: boolean;
  readonly passive: boolean;
  readonly once: boolean;
  removed: boolean;
  /** The abort step that removes the listener when the `signal` of its options aborts. */
  removal: { readonly signal: AbortSignal; readonly step: () => void } | undefined;
}

interface SignalState {
  aborted: boolean;
  reason: unknown;
  /** The internal abort steps. They run before the `abort` event, so no listener can stop them. */
  readonly steps: Set<() => void>;
  /** The signal comes from `AbortSignal.any`. Only its sources abort it. */
  dependent: boolean;
  /** The sources of a dependent signal. A source that no one else holds can go, as the dependent can no longer abort. */
  readonly sources: Source[];
  /** The dependent signals of a source. The collector can free a dependent without an abort listener or step. */
  readonly dependents: Set<WeakRef<AbortSignal>>;
  /** The dependent signals with an `abort` listener or an abort step. The source keeps them alive. */
  readonly retained: Set<AbortSignal>;
  /** The value of `onabort` and the listener that calls it. */
  handler: { value: object; readonly listener: Listener } | undefined;
}

/** A source of a dependent signal, and the weak reference to the dependent that the source keeps. */
interface Source {
  readonly signal: WeakRef<AbortSignal>;
  readonly ref: WeakRef<AbortSignal>;
}

const events = new PrivateMap<Event, EventState>();
const targets = new PrivateMap<EventTarget, Listener[]>();
const signals = new PrivateMap<AbortSignal, SignalState>();

/** Remove the weak reference of a source to a dependent signal that the collector freed. */
const collected = new FinalizationRegistry<{
  readonly dependents: Set<WeakRef<AbortSignal>>;
  readonly ref: WeakRef<AbortSignal>;
}>(({ dependents, ref }) => dependents.delete(ref));

/** The key that only the internal calls of the `AbortSignal` constructor give. */
const CREATE = Symbol("create");

function eventState(value: unknown): EventState {
  const state = events.get(value as Event);
  if (state === undefined) throw new TypeError("the value is not an Event");
  return state;
}

function listenersOf(value: unknown): Listener[] {
  const listeners = targets.get(value as EventTarget);
  if (listeners === undefined) throw new TypeError("the value is not an EventTarget");
  return listeners;
}

function signalState(value: unknown): SignalState {
  const state = signals.get(value as AbortSignal);
  if (state === undefined) throw new TypeError("the value is not an AbortSignal");
  return state;
}

/** Convert `value` as a Web IDL nullable `EventListener`. */
function callbackOf(value: unknown): EventListenerOrEventListenerObject | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "object" && typeof value !== "function") throw new TypeError("the listener is not an object");
  return value as EventListenerOrEventListenerObject;
}

/** Convert listener `options` as Web IDL does: a value that is not an object is the `capture` flag. */
function optionsOf(options: unknown): Readonly<Record<string, unknown>> {
  if (typeof options !== "object" && typeof options !== "function" && options !== undefined)
    return { capture: options };
  return dictionary(options, "the options");
}

export class Event {
  constructor(...args: [type: string, eventInit?: EventInit]) {
    needs(args, 1, "Event");
    const type = domString(args[0]);
    const init = dictionary(args[1], "the event init");
    events.set(this, {
      type,
      bubbles: Boolean(init.bubbles),
      cancelable: Boolean(init.cancelable),
      composed: Boolean(init.composed),
      timeStamp: now(),
      target: null,
      currentTarget: null,
      dispatching: false,
      trusted: false,
      canceled: false,
      passive: false,
      stopped: false,
      stoppedImmediately: false,
    });
    // Web IDL makes `isTrusted` an own property that no script can redefine.
    Object.defineProperty(this, "isTrusted", { get: isTrusted, enumerable: true });
  }

  declare readonly isTrusted: boolean;

  get type(): string {
    return eventState(this).type;
  }

  get target(): EventTarget | null {
    return eventState(this).target;
  }

  get currentTarget(): EventTarget | null {
    return eventState(this).currentTarget;
  }

  /** 2 (at the target) during a dispatch, 0 otherwise. A target has no tree, so it has no other phase. */
  get eventPhase(): number {
    return eventState(this).dispatching ? 2 : 0;
  }

  get bubbles(): boolean {
    return eventState(this).bubbles;
  }

  get cancelable(): boolean {
    return eventState(this).cancelable;
  }

  get composed(): boolean {
    return eventState(this).composed;
  }

  get defaultPrevented(): boolean {
    return eventState(this).canceled;
  }

  get timeStamp(): number {
    return eventState(this).timeStamp;
  }

  composedPath(): EventTarget[] {
    const target = eventState(this).currentTarget;
    return target === null ? [] : [target];
  }

  stopPropagation(): void {
    eventState(this).stopped = true;
  }

  stopImmediatePropagation(): void {
    const state = eventState(this);
    state.stopped = true;
    state.stoppedImmediately = true;
  }

  preventDefault(): void {
    const state = eventState(this);
    if (state.cancelable && !state.passive) state.canceled = true;
  }
}

function isTrusted(this: Event): boolean {
  return eventState(this).trusted;
}

export class CustomEvent<T = unknown> extends Event {
  readonly #detail: T | null;

  constructor(...args: [type: string, eventInit?: CustomEventInit<T>]) {
    needs(args, 1, "CustomEvent");
    super(...args);
    this.#detail = (dictionary(args[1], "the event init").detail as T | undefined) ?? null;
  }

  get detail(): T | null {
    return this.#detail;
  }
}

export class EventTarget {
  constructor() {
    targets.set(this, []);
  }

  addEventListener(
    ...args: [
      type: string,
      callback: EventListenerOrEventListenerObject | null,
      options?: boolean | AddEventListenerOptions,
    ]
  ): void {
    const listeners = listenersOf(this);
    needs(args, 2, "addEventListener");
    const type = domString(args[0]);
    const callback = callbackOf(args[1]);
    const fields = optionsOf(args[2]);
    const capture = Boolean(fields.capture);
    const once = Boolean(fields.once);
    const passive = Boolean(fields.passive);
    const signal = fields.signal as AbortSignal | undefined;

    if (signal !== undefined && signalState(signal).aborted) return;
    if (callback === null) return;
    const same = (listener: Listener) =>
      listener.type === type && listener.callback === callback && listener.capture === capture;
    if (listeners.some(same)) return;
    const listener: Listener = { type, callback, capture, passive, once, removed: false, removal: undefined };
    listeners.push(listener);
    if (signal !== undefined) {
      const step = () => removeListener(this, listener);
      signalState(signal).steps.add(step);
      listener.removal = { signal, step };
      retain(signal);
    }
    retain(this);
  }

  removeEventListener(
    ...args: [
      type: string,
      callback: EventListenerOrEventListenerObject | null,
      options?: boolean | EventListenerOptions,
    ]
  ): void {
    const listeners = listenersOf(this);
    needs(args, 2, "removeEventListener");
    const type = domString(args[0]);
    const callback = callbackOf(args[1]);
    const capture = Boolean(optionsOf(args[2]).capture);
    if (callback === null) return;
    const listener = listeners.find(
      (listener) => listener.type === type && listener.callback === callback && listener.capture === capture,
    );
    if (listener !== undefined) removeListener(this, listener);
  }

  dispatchEvent(...args: [event: Event]): boolean {
    listenersOf(this);
    needs(args, 1, "dispatchEvent");
    const event = args[0];
    const state = eventState(event);
    if (state.dispatching) throw new DOMException("the event is already being dispatched", "InvalidStateError");
    state.trusted = false;
    return dispatch(this, event, state);
  }
}

function removeListener(target: EventTarget, listener: Listener): void {
  const listeners = listenersOf(target);
  const index = listeners.indexOf(listener);
  if (index !== -1) listeners.splice(index, 1);
  listener.removed = true;
  if (listener.removal !== undefined) {
    signalState(listener.removal.signal).steps.delete(listener.removal.step);
    retain(listener.removal.signal);
    listener.removal = undefined;
  }
  retain(target);
}

/** Dispatch `event` at `target` in two passes: the capture listeners, then the other listeners. */
function dispatch(target: EventTarget, event: Event, state: EventState): boolean {
  state.dispatching = true;
  state.target = target;
  state.currentTarget = target;
  try {
    invoke(target, event, state, true);
    invoke(target, event, state, false);
  } finally {
    state.dispatching = false;
    state.currentTarget = null;
    state.stopped = false;
    state.stoppedImmediately = false;
  }
  return !state.canceled;
}

function invoke(target: EventTarget, event: Event, state: EventState, capture: boolean): void {
  // A `stopPropagation` before the dispatch or in the capture pass also stops this pass.
  if (state.stopped) return;
  // Each pass runs on a copy of the list. A listener added in this pass waits, and a removed listener does not run.
  for (const listener of [...listenersOf(target)]) {
    if (listener.removed || listener.type !== state.type || listener.capture !== capture) continue;
    if (listener.once) removeListener(target, listener);
    state.passive = listener.passive;
    try {
      const callback = listener.callback;
      if (typeof callback === "function") {
        callback.call(target, event);
      } else {
        const handleEvent: unknown = callback.handleEvent;
        if (typeof handleEvent !== "function") throw new TypeError("the listener has no handleEvent function");
        handleEvent.call(callback, event);
      }
    } catch (error) {
      reportError(error);
    }
    state.passive = false;
    if (state.stoppedImmediately) break;
  }
}

export class AbortSignal extends EventTarget {
  /** Only this module makes a signal: use an `AbortController` or a static method. */
  constructor(key?: typeof CREATE) {
    if (key !== CREATE) throw new TypeError("AbortSignal has no public constructor: use AbortController");
    super();
    signals.set(this, {
      aborted: false,
      reason: undefined,
      steps: new Set(),
      dependent: false,
      sources: [],
      dependents: new Set(),
      retained: new Set(),
      handler: undefined,
    });
  }

  /** A signal that has aborted with `reason`. `undefined` gives an `AbortError`. */
  static abort(reason?: unknown): AbortSignal {
    const signal = new AbortSignal(CREATE);
    const state = signalState(signal);
    state.aborted = true;
    state.reason = reason === undefined ? abortError() : reason;
    return signal;
  }

  /** A signal that aborts with the reason of the first of `signals` that aborts. */
  static any(...args: [signals: Iterable<AbortSignal>]): AbortSignal {
    needs(args, 1, "AbortSignal.any");
    const value: unknown = args[0];
    if ((typeof value !== "object" && typeof value !== "function") || value === null) {
      throw new TypeError("the signals are not an iterable object");
    }
    // Web IDL checks each value when the iterator gives it, before it asks for the next value.
    const iterator = (value as Iterable<unknown>)[Symbol.iterator]();
    const sources: { readonly signal: AbortSignal; readonly state: SignalState }[] = [];
    for (;;) {
      // A result that is not an object fails here or in `signalState`, each time with a `TypeError`.
      const next = iterator.next() as IteratorResult<unknown>;
      if (next.done) break;
      const item = next.value;
      sources.push({ signal: item as AbortSignal, state: signalState(item) });
    }
    const signal = new AbortSignal(CREATE);
    const state = signalState(signal);
    const aborted = sources.find((source) => source.state.aborted);
    if (aborted !== undefined) {
      state.aborted = true;
      state.reason = aborted.state.reason;
      return signal;
    }
    state.dependent = true;
    for (const source of sources) {
      if (!source.state.dependent) link(signal, source.signal);
      else {
        for (const root of source.state.sources) {
          const live = deref(root.signal);
          if (live !== undefined) link(signal, live);
        }
      }
    }
    return signal;
  }

  /** A signal that aborts with a `TimeoutError` after `milliseconds`. */
  static timeout(...args: [milliseconds: number]): AbortSignal {
    needs(args, 1, "AbortSignal.timeout");
    const milliseconds = Math.trunc(+args[0]);
    if (!Number.isFinite(milliseconds) || milliseconds < 0 || milliseconds > Number.MAX_SAFE_INTEGER) {
      throw new TypeError("the timeout is not a whole number in 0..2^53-1");
    }
    const signal = new AbortSignal(CREATE);
    wait(milliseconds, () => signalAbort(signal, new DOMException("the signal timed out", "TimeoutError")));
    return signal;
  }

  get aborted(): boolean {
    return signalState(this).aborted;
  }

  get reason(): unknown {
    return signalState(this).reason;
  }

  throwIfAborted(): void {
    const state = signalState(this);
    if (state.aborted) throw state.reason;
  }

  get onabort(): ((this: AbortSignal, event: Event) => unknown) | null {
    return (signalState(this).handler?.value as (this: AbortSignal, event: Event) => unknown) ?? null;
  }

  // A value that is not an object clears the handler. A new object keeps the position of the handler listener.
  set onabort(value: ((this: AbortSignal, event: Event) => unknown) | null) {
    const state = signalState(this);
    const object: unknown = value;
    if ((typeof object !== "object" && typeof object !== "function") || object === null) {
      if (state.handler !== undefined) removeListener(this, state.handler.listener);
      state.handler = undefined;
      return;
    }
    if (state.handler !== undefined) {
      state.handler.value = object;
      return;
    }
    const handle = (event: Event) => {
      const handler = state.handler?.value;
      if (typeof handler === "function" && handler.call(this, event) === false) event.preventDefault();
    };
    const listener: Listener = {
      type: "abort",
      callback: handle,
      capture: false,
      passive: false,
      once: false,
      removed: false,
      removal: undefined,
    };
    state.handler = { value: object, listener };
    listenersOf(this).push(listener);
    retain(this);
  }
}

export class AbortController {
  readonly #signal = new AbortSignal(CREATE);

  /** The signal of this controller. Each read gives the same signal. */
  get signal(): AbortSignal {
    return this.#signal;
  }

  /** Abort the signal with `reason`, once. `undefined` gives an `AbortError`. */
  abort(reason?: unknown): void {
    signalAbort(this.#signal, reason);
  }
}

function abortError(message = "the signal is aborted without reason"): DOMException {
  return new DOMException(message, "AbortError");
}

/**
 * A signal that only the host aborts, with its abort function. The abort reason is an `AbortError` with `message`. No
 * public member takes part, so a plugin that changes a prototype or a global does not change the abort.
 */
export function hostSignal(): { readonly signal: AbortSignal; readonly abort: (message: string) => void } {
  const signal = new AbortSignal(CREATE);
  return { signal, abort: (message) => signalAbort(signal, abortError(message)) };
}

/** Make `signal` a dependent of `source`. */
function link(signal: AbortSignal, source: AbortSignal): void {
  const state = signalState(signal);
  if (state.sources.some((known) => deref(known.signal) === source)) return;
  const ref = new StartWeakRef(signal);
  const dependents = signalState(source).dependents;
  dependents.add(ref);
  state.sources.push({ signal: new StartWeakRef(source), ref });
  register(collected, signal, { dependents, ref }, ref);
}

/** Keep a dependent signal alive through its sources while it has an `abort` listener or an abort step. */
function retain(target: EventTarget): void {
  const state = signals.get(target as AbortSignal);
  if (state === undefined || state.sources.length === 0) return;
  const signal = target as AbortSignal;
  const keep = state.steps.size > 0 || listenersOf(signal).some((listener) => listener.type === "abort");
  for (const known of state.sources) {
    const source = deref(known.signal);
    if (source === undefined) continue;
    const retained = signalState(source).retained;
    if (keep) retained.add(signal);
    else retained.delete(signal);
  }
}

/** Drop the links of `signal` to its sources and its dependents. An aborted signal needs none of them. */
function release(signal: AbortSignal, state: SignalState): void {
  for (const { signal: source, ref } of state.sources) {
    unregister(collected, ref);
    const live = deref(source);
    if (live === undefined) continue;
    const sourceState = signalState(live);
    sourceState.dependents.delete(ref);
    sourceState.retained.delete(signal);
  }
  state.sources.length = 0;
  for (const ref of state.dependents) unregister(collected, ref);
  state.dependents.clear();
  state.retained.clear();
}

/** Abort `signal` and each of its dependents with `reason`. Each state changes before the first step or listener runs. */
function signalAbort(signal: AbortSignal, reason: unknown): void {
  const state = signalState(signal);
  if (state.aborted) return;
  state.aborted = true;
  state.reason = reason === undefined ? abortError() : reason;
  const aborted: [AbortSignal, SignalState][] = [[signal, state]];
  for (const ref of state.dependents) {
    const dependent = deref(ref);
    if (dependent === undefined) continue;
    const dependentState = signalState(dependent);
    dependentState.aborted = true;
    dependentState.reason = state.reason;
    aborted.push([dependent, dependentState]);
  }
  for (const [each, eachState] of aborted) release(each, eachState);
  for (const [each, eachState] of aborted) {
    const steps = [...eachState.steps];
    eachState.steps.clear();
    for (const step of steps) step();
    const event = new Event("abort");
    const abortState = eventState(event);
    abortState.trusted = true;
    dispatch(each, event, abortState);
  }
}

/** Call `done` after `milliseconds`. A delay longer than one timer waits in several timers. */
function wait(milliseconds: number, done: () => void): void {
  const delay = Math.min(milliseconds, LONGEST_DELAY);
  setTimeout(() => {
    if (milliseconds > delay) wait(milliseconds - delay, done);
    else done();
  }, delay);
}

webClass(Event, "Event");
webClass(CustomEvent, "CustomEvent");
webClass(EventTarget, "EventTarget");
webClass(AbortSignal, "AbortSignal");
webClass(AbortController, "AbortController");
