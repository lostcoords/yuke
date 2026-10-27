// The host of `createHost` in `yuke:test`: the plugins under test in the runtime of the test, their sessions, and the
// fake model. The app of the test does the work through the natives of the test host.

import { underSignal } from "yuke:internal/events";
import {
  sessionRespond,
  testHostCall,
  testHostClose,
  testHostCreate,
  testHostRecord,
  testHostRun,
  testHostSettle,
  type WireMedia,
} from "yuke:internal/native";
import { give } from "yuke:internal/plugins";
import { flush, sessionsOf } from "yuke:internal/sessions";
import { folder } from "yuke:internal/test";
import type { Frozen, ViewEvent } from "yuke:plugins";
import type { Block, InteractionResponse, SessionId, SessionSettings, SessionUpdate } from "yuke:protocol";
import type {
  CallOutcome,
  CallsOptions,
  FakeModel,
  HookEvents,
  HookResults,
  Host,
  HostOptions,
  OperationOptions,
  Reply,
  ReplyOptions,
  ScriptedCall,
  TestMedia,
  TestQuestion,
  TestSession,
  ToolOutcome,
} from "yuke:test";
import type { ToolMedia } from "yuke:tools";
import { Transcript } from "yuke:transcript";

/** The model of a session when the test names none. The fake model answers each model of a provider with an API key. */
const TEST_MODEL = { provider: "minimax", model: "MiniMax-M3" } as const;

/** The scripted replies of each fake model. */
const scripts = new WeakMap<FakeModel, readonly Reply[]>();

/** A test creates one host. */
let created = false;

export function createFakeModel(replies: readonly Reply[]): FakeModel {
  const model: FakeModel = Object.freeze({
    get requests() {
      return testHostRecord().requests;
    },
  });
  scripts.set(model, [...replies]);
  return model;
}

export const reply = Object.freeze({
  text: (text: string, options?: ReplyOptions): Reply => ({
    kind: "text",
    text,
    inputTokens: options?.inputTokens ?? 0,
  }),
  toolCall: (name: string, args: unknown, options?: CallsOptions): Reply => ({
    kind: "toolCalls",
    text: options?.text ?? "",
    calls: [{ name, args }],
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

/** Wait until the transcripts and the records of the host hold each update and report before this call. */
async function settle(): Promise<void> {
  await flush();
  await testHostSettle();
}

/** The media item `item` for the test host: its path, or its bytes in base64. */
function wireMedia(item: ToolMedia): { mimeType: string; path: string } | { mimeType: string; base64: string } {
  if (item.bytes === undefined) return { mimeType: item.mimeType, path: item.path };
  let binary = "";
  // A spread of a large array overflows the stack, so the bytes go in parts.
  for (let start = 0; start < item.bytes.length; start += 32_768) {
    binary += String.fromCharCode(...item.bytes.subarray(start, start + 32_768));
  }
  return { mimeType: item.mimeType, base64: btoa(binary) };
}

/** The media item `item` of the test host, with its bytes. */
function testMedia(item: WireMedia): TestMedia {
  const bytes = Uint8Array.from(atob(item.base64), (char) => char.charCodeAt(0));
  return Object.freeze({ mimeType: item.mimeType, size: item.size, bytes });
}

/** The response to `update`, a question of a plugin, from `answer`. */
function responseOf(
  update: Frozen<Extract<SessionUpdate, { sessionUpdate: "interaction_requested" }>>,
  value: boolean | string | undefined,
): InteractionResponse {
  const request = update.request;
  if (value === undefined) return { kind: "canceled" };
  if (request.kind === "confirm") {
    if (typeof value !== "boolean") throw new TypeError(`the answer to the confirm "${request.title}" is no boolean`);
    return { kind: "confirm", value };
  }
  if (typeof value !== "string") throw new TypeError(`the answer to the ${request.kind} "${request.title}" is no text`);
  return { kind: request.kind, value };
}

export async function createHost(options: HostOptions): Promise<Host> {
  if (created) throw new Error("a test creates one host");
  created = true;
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
  const replies = options.model === undefined ? [] : (scripts.get(options.model) ?? []);
  await testHostCreate({ plugins, replies }).promise;
  await settle();

  const stop = new AbortController();
  const sessions = sessionsOf("test", stop.signal);
  const questions: TestQuestion[] = [];
  /** The sessions that the test closed. */
  const closed = new Set<SessionId>();
  let closing: Promise<void> | undefined;

  /** Record the question of `update` in the session `id`, and answer it. */
  const ask = (id: SessionId, update: Frozen<SessionUpdate>): void => {
    if (update.sessionUpdate !== "interaction_requested") return;
    const question: TestQuestion = Object.freeze({ sessionId: id, source: update.source, request: update.request });
    questions.push(question);
    const respond = (answer: () => boolean | string | undefined): void => {
      // A close ends the question, so a later answer has no question to reach.
      if (closed.has(id) || stop.signal.aborted) return;
      try {
        sessionRespond([id, update.interactionId, responseOf(update, answer())]);
      } catch (error) {
        // The cancel ends the operation that asked, and the error fails the test.
        sessionRespond([id, update.interactionId, { kind: "canceled" }]);
        throw error;
      }
    };
    let value: ReturnType<NonNullable<HostOptions["answer"]>>;
    try {
      value = options.answer?.(question);
    } catch (error) {
      respond(() => {
        throw error;
      });
      return;
    }
    if (value instanceof Promise) {
      // A rejection that no code handles is a fault, so a failed answer fails the test.
      void value.then(
        (answer) => respond(() => answer),
        (error: unknown) =>
          respond(() => {
            throw error;
          }),
      );
    } else {
      respond(() => value);
    }
  };

  const openSession = async (settings?: Partial<SessionSettings>): Promise<TestSession> => {
    let current: SessionSettings = {
      model: settings?.model ?? TEST_MODEL,
      settings: settings?.settings ?? {
        maxOutputTokens: null,
        reasoning: { thinking: null, effort: null },
        temperature: null,
        topP: null,
        toolChoice: "auto",
        outputSchema: null,
      },
      cwd: settings?.cwd ?? folder(),
    };
    const id = await sessions.create(current);
    const transcript = new Transcript();
    const handle = await sessions.open(id, {
      tail: 1000,
      signal: stop.signal,
      event(event: ViewEvent) {
        transcript.apply(event);
        if ("snapshot" in event) for (const update of event.snapshot.updates) ask(id, update);
        else ask(id, event.update);
      },
    });
    await settle();
    return Object.freeze({
      id,
      transcript,
      async send(text: string, operation?: OperationOptions): Promise<void> {
        operation?.signal?.throwIfAborted();
        const cancel = (): void => handle.cancel();
        operation?.signal?.addEventListener("abort", cancel, { once: true });
        try {
          await handle.input([{ user_text: text }]);
          await handle.idle();
        } finally {
          operation?.signal?.removeEventListener("abort", cancel);
        }
        await settle();
        // A cancel ends the turn early, and `send` rejects as `run` and `call` do.
        operation?.signal?.throwIfAborted();
      },
      async run<K extends keyof HookEvents>(
        point: K,
        event: HookEvents[K],
        operation?: OperationOptions,
      ): Promise<HookResults[K]> {
        let sent: unknown = event;
        if (point === "tool.after") {
          const after = event as HookEvents["tool.after"];
          sent = { ...after, result: { ...after.result, media: (after.result.media ?? []).map(wireMedia) } };
        } else if (point === "prompt.build") {
          sent = { sections: Object.entries((event as HookEvents["prompt.build"]).sections) };
        } else if (point === "input.before") {
          const input = event as HookEvents["input.before"];
          sent = { ...input, blocks: input.blocks.map((block) => ("mimeType" in block ? wireMedia(block) : block)) };
        }
        const result = await underSignal(operation?.signal, () => testHostRun([id, point, sent]));
        await settle();
        // The hook point ends early after a cancel, so its decision is no answer.
        operation?.signal?.throwIfAborted();
        let answer: unknown = result ?? undefined;
        if (point === "tool.after") {
          const outcome = result as Omit<ToolOutcome, "media"> & { readonly media: readonly WireMedia[] };
          answer = { ...outcome, media: outcome.media.map(testMedia) };
        } else if (point === "prompt.build") {
          const pairs = (result as { sections: readonly (readonly [string, string])[] }).sections;
          answer = { sections: Object.fromEntries(pairs) };
        } else if (point === "input.before" && typeof result === "object" && result !== null) {
          const blocks = (result as { replace: { blocks: readonly (Block | WireMedia)[] } }).replace.blocks;
          answer = { replace: { blocks: blocks.map((block) => ("base64" in block ? testMedia(block) : block)) } };
        }
        return answer as HookResults[K];
      },
      async call(tool: string, args: unknown, operation?: OperationOptions): Promise<CallOutcome> {
        const result = await underSignal(operation?.signal, () => testHostCall([id, tool, args]));
        await settle();
        // The tool ends early after a cancel, so its result is no answer.
        operation?.signal?.throwIfAborted();
        return { ...result, media: result.media.map(testMedia) };
      },
      async setSettings(changed: Partial<SessionSettings>): Promise<void> {
        const next = { ...current, ...changed };
        await handle.setSettings(next);
        current = next;
        await settle();
      },
      async close(): Promise<void> {
        closed.add(id);
        await sessions.close(id, { stopJobs: true });
        await settle();
      },
    } satisfies TestSession);
  };

  const close = (): Promise<void> => {
    closing ??= (async () => {
      stop.abort(new Error("the host closed"));
      await testHostClose(null).promise;
      await settle();
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
    questions,
    openSession,
    close,
    [Symbol.asyncDispose]: close,
  } satisfies Host);
}
