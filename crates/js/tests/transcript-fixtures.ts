// The fixtures of the tests of `yuke:transcript`: the settings of a session, saved and live updates, and a fed transcript.

import type {
  Answer,
  Commit,
  ConsumedInput,
  DraftId,
  FinishReason,
  LiveUpdate,
  ModelUpdate,
  SessionSettings,
  SessionUpdate,
  StoredEvent,
} from "yuke:protocol";
import { Transcript } from "yuke:transcript";

export const settings: SessionSettings = {
  model: { provider: "p", model: "m" },
  settings: {
    reasoning: {},
    toolChoice: "auto",
  },
  cwd: "/w",
};

/** The saved event `seq` with the commit fields of `fields`, which consumed `consumed`. */
export function commit(seq: number, fields: Partial<Commit>, consumed: ConsumedInput[] = []): StoredEvent {
  return {
    seq,
    sessionUpdate: "commit",
    commit: { blocks: [], ...fields },
    consumed,
  };
}

/** The answer of a model that ended with `finishReason`. */
export function answer(finishReason: FinishReason): Answer {
  return { origin: { model: "m", baseUrl: "https://p" }, usage: {}, finishReason };
}

/** The live update `event` of the draft `draftId`. */
export function model(draftId: DraftId, event: ModelUpdate): LiveUpdate {
  return { sessionUpdate: "model", draftId, event };
}

/** A transcript after a snapshot with `updates`. */
export function opened(updates: SessionUpdate[] = []): Transcript {
  const transcript = new Transcript();
  transcript.apply({ kind: "snapshot", snapshot: { settings, updates } });
  return transcript;
}

/** `transcript` after each of `updates`. */
export function fed(transcript: Transcript, updates: readonly SessionUpdate[]): Transcript {
  for (const update of updates) transcript.apply({ kind: "update", update });
  return transcript;
}
