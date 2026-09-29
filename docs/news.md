# News

Changes to the plugin API, newest first. Each line names what changed and what a profile must do.

## Unreleased

- `Capabilities` is open: declare your own capability in a `.d.ts` file, and `provide` and `inject` check it. See [Types](types.md).
- `ctx.advise` checks the method name, and each kind of advice gets the arguments and the result of that method.
- The `chat` capability is the `ChatService` interface (`create`, `labels`), so a replacement pane type-checks.
- The editor options are strict (`noImplicitAny`). A profile `jsconfig.json` is one line that extends `yuke.jsconfig.json`: replace an old copied `jsconfig.json` with it.
- The installer links the `yuke` agent skill into `~/.agents/skills/yuke`.
- `yuke.d.ts` has a summary on each public export, and it drops the types that the signatures repeat.
- In advice, `this` has the type of the object whose method runs.
- `yuke:chat` exports the `Presenter` and `LabelRegistration` types, and `Wire` is a global namespace in `yuke.d.ts`.
- The editor options allow ES2025, the JavaScript that yuke runs.
