# AGENTS.md

The codebase is yours. You decide what it is for and how it is built, and you keep building on it.

Write in ASD-STE100: one meaning per word, active voice, simple tense, one instruction per sentence.
Look up an API on the internet or in this tree. Do not guess.

The project is pre-release. Break an API when a better design needs it. Do not keep the old shape. Do not add a shim or
a deprecation path.
Fix the cause, not the symptom. Rewrite code when the rewrite is simpler.
Ask the user before you add a dependency.

## Development

Run every tool through mise: `mise exec -- cargo ...`.
Before you finish, run `mise run check`.

Write each commit message as a Conventional Commit in imperative English: `feat(tui)!: show the cancel of a turn`.

## Code

- A comment says why, in one or two lines. A doc says what an item does, not how it came to be.
- Use full words in names. One word has one meaning in all modules: a `message` is what a user sends in a chat, and a
  `notice` is what a user reads.
- Validate an unknown value once, at the boundary that owns it. Pass typed values inward. Do not check again what a
  schema, a constructor, or a type already guarantees.
- Do not make a helper for one caller. Make it when it has more callers, when it hides a complex boundary, or when its
  name makes the caller clearer.
- Do not add code for an unlikely race or security case on your own. First tell the user the failure, its likelihood,
  and the cost of the code. Then get their approval.
- Give each error one of two shapes. A mix makes a printer of the chain show a text twice.
  - A context error writes its own text and returns the cause from `source`.
  - A transparent error writes the text of its inner error and returns the `source` of that inner error. It can add
    facts after that text.
- A trait error that the library only reports is `Box<dyn Error + Send + Sync>`. Use a concrete type only when the
  library acts on its kind.

## TypeScript and the plugin API

- When a familiar model exists (Deno, the web, Node, `@std`, the Vercel AI SDK), copy its names and shapes, and its
  `null` too. AI agents know these APIs, so they write correct code without our docs.
- Name the other APIs by these rules:
  - A registration returns a remover. `add*` adds an independent one, and `set*` replaces the one before it.
  - The core calls a callback option `on*`. A plugin calls a callback option `request*`.
  - A method that waits for a state starts with a verb: `waitFor*`. A bare adjective is a state.
  - When two targets are possible, the name says which one gets the effect: `notifyModel`, `closeForAll`.
- Give each parameter a plain name. Do not destructure a parameter. Destructure a value only when that is clearer, or
  when it keeps values fixed. Prefer dot notation, so the reader keeps the context.
- Do not police plugins. Check a plugin value only where yuke needs its shape. A bad plugin is not a fault of yuke.
- In the TUI, a transcript label, the working row, and a notice start with a capital letter. A key hint and the text
  after ` · ` start in lowercase. A name and the text of an error keep their case.

## Tests

- Name a test after the behavior it protects.
- Do not add a test that restates a type or a constant. Add a test to pin an invariant.
- Test observable behavior with independent expectations.
- Make a negative test reach the guard that it tests.
