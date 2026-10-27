// Type checks of `yuke:transcript`. `tsc -p crates/js/tsconfig.json` runs them; nothing executes this file.

import type { Sessions, ViewEvent } from "yuke:plugins";
import type { Entry, Transcript } from "yuke:transcript";
import type * as Runtime from "../modules/runtime/transcript.ts";

/** `true` only when `A` and `B` are the same type. */
type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends <T>() => T extends B ? 1 : 2 ? true : false;

/** A call that compiles only for `true`. */
declare function assert<T extends true>(): void;

// The runtime module exports exactly the declared values, so no export is missing and none is extra.
assert<Equal<keyof typeof Runtime, keyof typeof import("yuke:transcript")>>();

// The events of an open feed a transcript, and a gap goes back to the sessions.
export async function follow(sessions: Sessions, transcript: Transcript): Promise<void> {
  const handle = await sessions.open("id", { tail: 50, event: (event) => transcript.apply(event) });
  if (transcript.gap !== undefined) transcript.insert(await sessions.events(handle.id, transcript.gap));
  // @ts-expect-error: the snapshot is the first event, not a field of the handle.
  void handle.snapshot;
  // @ts-expect-error: `event` gets the snapshot and the updates.
  await sessions.open("id", { tail: 50, update: () => undefined });
}

// The close of a session aborts `handle.signal`. It is no event of the plugin.
// @ts-expect-error: `"closed"` is an event of the bridge only.
export const closed: ViewEvent = "closed";

// A view reads the entries and never changes them, so a cache by object stays true.
export function draw(transcript: Transcript, entry: Entry): void {
  // @ts-expect-error: the list is read-only.
  transcript.entries.push(entry);
  // @ts-expect-error: the inputs are read-only.
  transcript.pending.clear();
  if (entry.kind === "tool") {
    // @ts-expect-error: an entry is read-only.
    entry.output = "";
  }
}
