/**
 * The draft of the composer as the blocks of an input, and back. A paste span keeps its whole text in the draft, so the
 * input gets the text. An image span covers one U+FFFC and becomes a media block.
 */

import type { Block } from "yuke:protocol";
import type { Entry } from "yuke:transcript";
import type { EditorSpan, EditorState } from "yuke:tui";

/** A paste of more characters than this becomes a span that shows a label. */
export const PASTE_SPAN = 300;

/** The character that an image span covers: U+FFFC, the object replacement character. */
export const IMAGE = "￼";

/** The empty draft. */
export const EMPTY: EditorState = Object.freeze({ text: "", selection: { anchor: 0, head: 0 }, spans: [] });

/** The blocks of `draft`: its text between its images, each image a media block. A draft of white space has none. */
export function blocksOf(draft: EditorState): Block[] {
  const blocks: Block[] = [];
  let from = 0;
  const text = (to: number): void => {
    if (to > from) blocks.push({ user_text: draft.text.slice(from, to) });
  };
  for (const span of draft.spans) {
    if (span.kind !== "image") continue;
    text(span.from);
    blocks.push({ media: span.media });
    from = span.to;
  }
  text(draft.text.length);
  const blank = blocks.every((block) => "user_text" in block && block.user_text.trim() === "");
  return blank ? [] : blocks;
}

/** The draft of the blocks of an input, with an image span for each media block. The caret is at the end. */
export function draftOf(content: Extract<Entry, { kind: "input" }>["content"]): EditorState {
  let text = "";
  const spans: EditorSpan[] = [];
  for (const block of content) {
    if ("user_text" in block) text += block.user_text;
    else if ("media" in block) {
      spans.push({
        from: text.length,
        to: text.length + 1,
        kind: "image",
        label: `[image ${spans.length + 1}]`,
        media: block.media,
      });
      text += IMAGE;
    }
  }
  return { text, selection: { anchor: text.length, head: text.length }, spans };
}

/** `first` above `second`, a line end between them, each span kept. The caret is at the end. */
export function joined(first: EditorState, second: EditorState): EditorState {
  if (second.text === "") return { ...first, selection: { anchor: first.text.length, head: first.text.length } };
  const shift = first.text.length + 1;
  const text = `${first.text}\n${second.text}`;
  const spans = [
    ...first.spans,
    ...second.spans.map((span) => ({ ...span, from: span.from + shift, to: span.to + shift })),
  ];
  return { text, selection: { anchor: text.length, head: text.length }, spans };
}
