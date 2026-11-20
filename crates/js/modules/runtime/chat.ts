/** The code of the public module `yuke:chat`. Its declaration is `types/chat.d.ts`, and the check at the end compares the two. */

import { slashCompletions } from "yuke:internal/chat/commands";
import { ChatCompletions } from "yuke:internal/chat/completions";
import { ChatComposer } from "yuke:internal/chat/composer";
import { ChatDocument } from "yuke:internal/chat/document";
import { ChatQuestions } from "yuke:internal/chat/questions";
import { composerRows } from "yuke:internal/chat/rows";
import { ChatSession } from "yuke:internal/chat/session";
import { ChatWorking } from "yuke:internal/chat/working";

export {
  ChatCompletions,
  ChatComposer,
  ChatDocument,
  ChatQuestions,
  ChatSession,
  ChatWorking,
  composerRows,
  slashCompletions,
};

// The check against `types/chat.d.ts` keeps this code and the declarations of the authors in step.
const declared = {
  ChatSession,
  ChatComposer,
  ChatQuestions,
  ChatCompletions,
  ChatWorking,
  ChatDocument,
  slashCompletions,
  composerRows,
} satisfies typeof import("yuke:chat");
void declared;
