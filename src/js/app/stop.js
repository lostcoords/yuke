// One stop for every background id. Each id prefix has one owner: the built-ins own `job-`, and the agents plugin owns its catalog names.

/** @import { ToolContext } from "./types/ext.js" */
/** An owner returns null from `stop` when an id of its form names no work. */
/** @typedef {{ owns(id: string): boolean, stop(id: string, context: ToolContext): Promise<string | null>, ids(context: ToolContext): Promise<string[]> }} StopOwner */

/** @type {StopOwner[]} */
const owners = [];

/** Add an owner of ids. The disposer removes it. @param {StopOwner} owner @returns {() => void} */
export function own(owner) {
  owners.push(owner);
  return () => {
    const at = owners.indexOf(owner);
    if (at >= 0) owners.splice(at, 1);
  };
}

/** Stop the work that `id` names and answer its end text. An unknown id throws an error that lists the live ids. @param {string} id @param {ToolContext} context @returns {Promise<string>} */
export async function stop(id, context) {
  const owner = owners.find((candidate) => candidate.owns(id));
  const ended = owner ? await owner.stop(id, context) : null;
  if (ended !== null) return ended;
  /** @type {string[]} */
  const ids = [];
  for (const each of owners) ids.push(...await each.ids(context));
  throw new Error("The id " + id + " does not exist. " + (ids.length === 0 ? "Nothing runs." : "The ids are: " + ids.join(", ") + "."));
}
