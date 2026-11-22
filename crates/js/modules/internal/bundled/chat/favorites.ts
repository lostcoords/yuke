/**
 * The favorite models of the bundled chat: the `favorites` option. A favorite names a model and a reasoning level, so
 * one pick sets both. `/model` lists the favorites first, in their order.
 */

import type { ModelInfo, ProviderInfo, ReasoningChoice } from "yuke:protocol";

/** One entry of the `favorites` option. */
export interface Favorite {
  /** The word of its command, such as `sh` for `/sh`. Without it, the favorite has no command. */
  readonly name?: string | undefined;
  /** `provider/model`. A `*` in the model matches a version, such as `gpt-*-sol`, and the newest version wins. */
  readonly model: string;
  /** The reasoning level, such as `high`. */
  readonly reasoning: string;
  /** The key of its command, such as `ctrl+x s`. It needs `name`. */
  readonly key?: string | undefined;
}

/** A favorite that a ready provider has: its model and its reasoning choice. */
export interface FavoriteChoice {
  readonly favorite: Favorite;
  readonly provider: string;
  readonly model: ModelInfo;
  readonly reasoning: ReasoningChoice;
}

/** The model and the reasoning of `favorite` in `providers`, or `undefined` when no ready model or level matches. */
export function resolveFavorite(favorite: Favorite, providers: readonly ProviderInfo[]): FavoriteChoice | undefined {
  const slash = favorite.model.indexOf("/");
  if (slash < 0) return undefined;
  const provider = favorite.model.slice(0, slash);
  const pattern = favorite.model.slice(slash + 1);
  const models = providers.find((entry) => entry.id === provider)?.models ?? [];
  const model = pattern.includes("*") ? newest(models, pattern) : models.find((entry) => entry.id === pattern);
  const reasoning = model?.reasoning.find((choice) => choice.level === favorite.reasoning);
  return model === undefined || reasoning === undefined ? undefined : { favorite, provider, model, reasoning };
}

/** The model of `models` whose id matches `pattern` with the highest version in place of its `*`. */
function newest(models: readonly ModelInfo[], pattern: string): ModelInfo | undefined {
  const parts = pattern.split("*").map((part) => part.replace(/[.+?^${}()|[\]\\]/g, "\\$&"));
  const matcher = new RegExp(`^${parts.join("(\\d+(?:\\.\\d+)*)")}$`);
  let best: { readonly model: ModelInfo; readonly version: number[] } | undefined;
  for (const model of models) {
    const match = matcher.exec(model.id);
    if (match === null) continue;
    const version = match.slice(1).flatMap((group) => group.split(".").map(Number));
    if (best === undefined || compare(version, best.version) > 0) best = { model, version };
  }
  return best?.model;
}

/** The order of two versions: negative when `left` is older, positive when it is newer. */
function compare(left: readonly number[], right: readonly number[]): number {
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const difference = (left[index] ?? 0) - (right[index] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
}
