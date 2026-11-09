// Add tree marks to transcript labels. Add `"uses": ["chat"]` to the manifest entry.

import { ChatDocument } from "yuke:chat";

/** @param {import("yuke:plugins").PluginContext} ctx */
export function apply(ctx) {
  if (!ctx.get("tui")) return undefined;

  return ctx.get("chat").setPresentation((options) => {
    const inner = new ChatDocument(options.key, options.folds);
    /** @type {WeakMap<import("yuke:tui").TextItem, import("yuke:tui").TextItem>} */
    const cache = new WeakMap();
    return {
      get folds() {
        return inner.folds;
      },
      toggle: (transcript, key) => inner.toggle(transcript, key),
      toggleTools: (transcript) => inner.toggleTools(transcript),
      project: (transcript) => {
        const document = inner.project(transcript);
        const items = document.items.map((item) => {
          let result = cache.get(item);
          if (!result) {
            result = {
              key: item.key,
              sections: item.sections.map((section) =>
                section.kind === "label"
                  ? {
                      key: section.key,
                      kind: section.kind,
                      text: `└─ ${section.text}`,
                    }
                  : section,
              ),
            };
            cache.set(item, result);
          }
          return result;
        });
        return { key: document.key, items };
      },
    };
  });
}
