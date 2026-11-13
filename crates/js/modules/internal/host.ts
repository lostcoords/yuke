// The host of `createHost` in `yuke:test`: the plugins under test in the runtime of the test, their sessions, and the
// fake model. The app of the test does the work through the natives of the test host.

import { underSignal } from "yuke:internal/events";
import { setResponder } from "yuke:internal/hooks";
import {
  type Operation,
  sessionRespond,
  testHostCall,
  testHostClose,
  testHostCreate,
  testHostRecord,
  testHostRun,
  testWaitForSettled,
} from "yuke:internal/native";
import { give } from "yuke:internal/plugins";
import { sessionsOf } from "yuke:internal/sessions";
import { folder } from "yuke:internal/test";
import { jsonCopy } from "yuke:internal/values";
import { ClientRequestError, type Frozen, type SessionHandleEvent } from "yuke:plugins";
import type { ExtensionRequestParams, SessionId, SessionSettings, SessionUpdate } from "yuke:protocol";
import type {
  CallOutcome,
  CallsOptions,
  HookEvents,
  HookResults,
  Host,
  HostOptions,
  OperationOptions,
  Reply,
  ReplyOptions,
  ScriptedCall,
  TestQuestion,
  TestSession,
} from "yuke:test";
import { Transcript } from "yuke:transcript";

/** The model of a session when the test names none. The fake model answers each model of a provider with an API key. */
const TEST_MODEL = { provider: "minimax", model: "MiniMax-M3" } as const;

export const reply = Object.freeze({
  text: (text: string, options?: ReplyOptions): Reply => ({
    kind: "text",
    text,
    inputTokens: options?.inputTokens ?? 0,
  }),
  toolCalls: (calls: readonly ScriptedCall[], options?: CallsOptions): Reply => ({
    kind: "toolCalls",
    text: options?.text ?? "",
    calls: [...calls],
    inputTokens: options?.inputTokens ?? 0,
  }),
  cut: (calls: readonly ScriptedCall[]): Reply => ({ kind: "cut", calls: [...calls] }),
  overloaded: (): Reply => ({ kind: "overloaded" }),
  overflow: (): Reply => ({ kind: "overflow" }),
  failed: (text: string): Reply => ({ kind: "failed", text }),
  stall: (text = ""): Reply => ({ kind: "stall", text }),
});

/**
 * The operation of a plugin request that `onClientRequest` answers. It gives a JSON copy of the result, or a failure record as
 * the native does. A cancel ends the wait of the plugin, and a late answer has no effect.
 */
function responderOf(onClientRequest: NonNullable<HostOptions["onClientRequest"]>) {
  return (request: ExtensionRequestParams): Operation<unknown> => {
    let cancel = (): void => undefined;
    const promise = new Promise<unknown>((resolve, reject) => {
      cancel = () => reject({ cancelled: true });
      void (async () => {
        try {
          resolve(jsonCopy((await onClientRequest(request)) ?? null));
        } catch (error) {
          if (error instanceof ClientRequestError) {
            const data = error.data === undefined ? undefined : jsonCopy(error.data);
            reject({ code: error.code, message: error.message, data });
            return;
          }
          reject({ code: -32_603, message: String(error) });
          // A rejection that no code handles is a fault, so a failed `onClientRequest` fails the test.
          throw error;
        }
      })();
    });
    return { promise, cancel };
  };
}

export async function createHost(options: HostOptions): Promise<Host> {
  const plugins = options.plugins.map((plugin) => {
    if ("folder" in plugin) {
      return plugin.options === undefined
        ? { folder: plugin.folder }
        : { folder: plugin.folder, options: plugin.options };
    }
    const exports: Record<string, unknown> = {};
    if (plugin.apply !== undefined) exports.apply = plugin.apply;
    if (plugin.session !== undefined) exports.session = plugin.session;
    if (plugin.optionsSchema !== undefined) exports.optionsSchema = plugin.optionsSchema;
    give(plugin.name, exports);
    return {
      name: plugin.name,
      options: plugin.options ?? {},
      uses: plugin.uses ?? [],
      provides: plugin.provides ?? [],
    };
  });
  // A plugin can send a request while the host loads it.
  if (options.onClientRequest !== undefined) setResponder(responderOf(options.onClientRequest));
  await testHostCreate({ plugins, replies: options.replies ?? [] }).promise;
  await testWaitForSettled();

  const stop = new AbortController();
  const sessions = sessionsOf("test", stop.signal);
  const questions: TestQuestion[] = [];
  /** The sessions that the test closed. */
  const closed = new Set<SessionId>();
  let closing: Promise<void> | undefined;

  /** Record the question of `update` in the session `id`, and answer it. */
  const ask = (id: SessionId, update: Frozen<SessionUpdate>): void => {
    if (update.sessionUpdate !== "interactionRequested") return;
    const question: TestQuestion = Object.freeze({ sessionId: id, source: update.source, request: update.request });
    questions.push(question);
    // A rejection that no code handles is a fault, so a failed `onQuestion` fails the test.
    void (async () => {
      // A close ends the question, so a later answer or failure has no question to reach.
      const open = (): boolean => !closed.has(id) && !stop.signal.aborted;
      try {
        const answers = await options.onQuestion?.(question);
        if (open()) {
          sessionRespond([
            id,
            update.interactionId,
            answers === undefined ? { kind: "cancelled" } : { kind: "questions", answers: [...answers] },
          ]);
        }
      } catch (error) {
        if (!open()) return;
        // The cancel ends the operation that asked.
        sessionRespond([id, update.interactionId, { kind: "cancelled" }]);
        throw error;
      }
    })();
  };

  const openSession = async (settings?: Partial<SessionSettings>): Promise<TestSession> => {
    let current: SessionSettings = {
      model: settings?.model ?? TEST_MODEL,
      settings: settings?.settings ?? {
        reasoning: {},
        toolChoice: "auto",
      },
      cwd: settings?.cwd ?? folder(),
    };
    const id = await sessions.create(current);
    const transcript = new Transcript();
    const handle = await sessions.open(id, {
      tail: 1000,
      signal: stop.signal,
      onEvent(event: SessionHandleEvent) {
        transcript.apply(event);
        if (event.kind === "snapshot") for (const update of event.snapshot.updates) ask(id, update);
        else ask(id, event.update);
      },
    });
    await testWaitForSettled();
    return Object.freeze({
      id,
      transcript,
      async sendMessage(text: string, operation?: OperationOptions): Promise<void> {
        operation?.signal?.throwIfAborted();
        const cancel = (): void => handle.cancel();
        operation?.signal?.addEventListener("abort", cancel, { once: true });
        try {
          await handle.sendMessage({ content: [{ kind: "userText", text }] });
          await handle.waitForIdle();
        } finally {
          operation?.signal?.removeEventListener("abort", cancel);
        }
        await testWaitForSettled();
        // A cancel ends the turn early, and `sendMessage` rejects as `runHook` and `call` do.
        operation?.signal?.throwIfAborted();
      },
      async runHook<K extends keyof HookEvents>(
        point: K,
        event: HookEvents[K],
        operation?: OperationOptions,
      ): Promise<HookResults[K]> {
        const result = await underSignal(operation?.signal, () => testHostRun([id, point, event]));
        await testWaitForSettled();
        // The hook point ends early after a cancel, so its decision is no answer.
        operation?.signal?.throwIfAborted();
        return (result ?? undefined) as HookResults[K];
      },
      async call(tool: string, args: unknown, operation?: OperationOptions): Promise<CallOutcome> {
        const result = await underSignal(operation?.signal, () => testHostCall([id, tool, args]));
        await testWaitForSettled();
        // The tool ends early after a cancel, so its result is no answer.
        operation?.signal?.throwIfAborted();
        return result;
      },
      get settings(): SessionSettings {
        return current;
      },
      async setSettings(settings: SessionSettings): Promise<void> {
        await handle.setSettings(settings);
        current = settings;
        await testWaitForSettled();
      },
      async close(): Promise<void> {
        closed.add(id);
        await sessions.closeForAll(id);
        await testWaitForSettled();
      },
    } satisfies TestSession);
  };

  const close = (): Promise<void> => {
    closing ??= (async () => {
      stop.abort(new Error("the host closed"));
      setResponder(undefined);
      await testHostClose(null).promise;
      await testWaitForSettled();
    })();
    return closing;
  };

  return Object.freeze({
    get notices() {
      return testHostRecord().notices;
    },
    get events() {
      return testHostRecord().events;
    },
    get requests() {
      return testHostRecord().requests;
    },
    questions,
    openSession,
    close,
    [Symbol.asyncDispose]: close,
  } satisfies Host);
}
