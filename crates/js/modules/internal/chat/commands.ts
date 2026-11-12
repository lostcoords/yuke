/**
 * The slash commands of a composer: the completion provider of the commands that match a slash word, and the word of a
 * draft that Enter runs.
 */

import type { CompletionItem, CompletionProvider, SlashCommands } from "yuke:chat";
import { type CommandItem, fuzzyMatch, type OffsetRange } from "yuke:tui";

/** A draft of one slash word, such as `/mod`, and the text after it. */
const SLASH_DRAFT = /^(\/\S*)(\s[\s\S]*)?$/;

/** Enter on the slash word `word` runs `item`: text after the word needs a command that takes text. */
function runsCommand(item: CommandItem, word: string, hasText: boolean): boolean {
  return item.enabled && `/${item.slash}` === word && (!hasText || item.argumentHint !== undefined);
}

export function slashCompletions(commands: SlashCommands): CompletionProvider {
  return {
    complete: (context) => {
      const draft = SLASH_DRAFT.exec(context.text);
      if (draft === null) return undefined;
      const word = draft[1] as string;
      const text = draft[2];
      const items = commands.list().filter((item) => item.enabled && item.slash !== undefined);
      // Text after the word needs a command with a hint. Otherwise the draft stays a message.
      const ranked: readonly { readonly item: CommandItem; readonly ranges?: readonly OffsetRange[] }[] =
        text !== undefined
          ? items.filter((item) => runsCommand(item, word, true)).map((item) => ({ item }))
          : items
              .flatMap((item) => {
                const match = fuzzyMatch(word, `/${item.slash}`);
                return match === undefined ? [] : [{ item, score: match.score, ranges: match.ranges }];
              })
              // The sort is stable, so equal scores keep the order of the registry.
              .sort((a, b) => b.score - a.score);
      const args = text?.trim() || undefined;
      return {
        from: 0,
        to: word.length,
        items: ranked.map(({ item, ranges }): CompletionItem => {
          const name = `/${item.slash}`;
          return {
            label: item.argumentHint === undefined ? name : `${name} ${item.argumentHint}`,
            detail: item.description,
            ranges,
            // The text after the word stays, so Tab writes only the word then.
            insert: text !== undefined || item.argumentHint === undefined ? name : `${name} `,
            run: () => commands.run(item.name, args),
          };
        }),
      };
    },
  };
}

/** The length of the slash word of `text` that Enter runs as a command, or 0 when Enter sends `text`. */
export function commandWordLength(commands: SlashCommands, text: string): number {
  const draft = SLASH_DRAFT.exec(text);
  const word = draft?.[1];
  if (word === undefined) return 0;
  const hasText = draft?.[2] !== undefined;
  return commands.list().some((item) => runsCommand(item, word, hasText)) ? word.length : 0;
}
