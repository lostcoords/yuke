# docs-html

Throwaway maps of the codebase, read in a browser. Sources are read **live** from the
working tree, repo stats come from `cloc`, and a built-in agent lets you chat with the code.

## Running

The server is a [uv](https://docs.astral.sh/uv/) script — its dependencies are declared inline
(PEP 723), so `uv run` fetches them into a throwaway environment automatically.

```
uv run docs-html/serve.py          # http://127.0.0.1:8765/
uv run docs-html/serve.py 9000     # another port
```

`uv` itself is provided by **mise** through a local `docs-html/mise.toml` (untracked, and layered
only while your shell is inside `docs-html/` — the project's root `.mise.toml` is untouched):

```
cd docs-html && mise install       # installs uv the first time
```

Binds loopback. `cloc` must be on `PATH` for the stats (`brew install cloc`).

The pages are styled with **Tailwind via the Play CDN** (compiled in the browser, JIT), so any
utility class the agent writes into a page takes effect on the next reload — no build step. The
trade-off is that rendering needs network access to `cdn.tailwindcss.com`. The chat itself only needs
the local `yuked` daemon (the daemon, in turn, reaches the model provider).

## The on-page agent

Click **✦ ask** (bottom-right, on every page) to open the code-guide agent as a **right sidebar**.
On wide screens it reserves space and shifts the page left (nothing is hidden); on narrow screens it
overlays.

The chat **is a real `yuked` session**, not a server-side proxy: the page connects straight to a
local yuke daemon with the vendored SDK (`vendor/yuke/`), creates a **yolo** session rooted at
`docs-html/`, and streams the turn from the daemon's broadcasts. The credential and provider live in
the daemon — there is no key panel here. `serve.py` furnishes only the system prompt and paths the
page hands to `session.create` (`/api/guide`). This doubles as an end-to-end exercise of the daemon:
every question drives `session.create` / `send_input` / `subscription.set` / resync / the fs + exec
tools against live `yuked`.

The session is rooted at `docs-html/` (not the repo root) so its sessions stay **separate from your
own coding sessions** — the picker then shows only docs conversations. The daemon's file tools take
absolute paths, so the system prompt gives the model the repo's absolute path; it reads and searches
the source there and cites `path:line` repo-relative. It can **edit these doc pages** by writing
files under `docs-html/` — hot reload swaps the page in on save. It **cannot** drive your browser
(there is no client-side tool for it), so instead of jumping your view it names the page + anchor.

Replies render as **Markdown** (headings, lists, links, bold/italic, and fenced code blocks —
Odin/JS blocks get the same syntax highlighting as the page excerpts). Rendering escapes HTML first,
so model output can't inject markup.

- **Continue vs. new session** — the conversation is a daemon session and it persists there. Its id
  is remembered in this browser's `localStorage`, so it **continues across a full restart**, not just
  a hot reload. Hit **＋ new** to start a fresh session.
- **sessions ▾** — lists the **docs sessions only** (`session.list` scoped to the `docs-html/`
  workspace id from `workspace.describe`). Click one to continue it.
- **model dropdown** (bottom of the panel) — populated from `catalog.list`, grouped by provider. The
  choice is remembered in `localStorage` and used for the next new session; switching it on a live
  session `session.patch`es the model (effective on the next run). Empty = the daemon's default.

**What the agent knows** — its system prompt (in `serve.py`) is a short primer: the repo layout
(`src/wire` authoritative, `src/daemon`, `src/js`, `src/tui`), the load-bearing invariants (single
`nbio` reactor, the pump as sole fan-out, tickets-not-pointers, clone-at-the-frame-boundary,
assert-or-handle), and how to work (read/search before answering, cite `path:line`, and that it
cannot drive the browser). Add your own context in **`docs-html/context.md`** — if that file exists,
its contents are appended to the prompt (read live on each new session), so you can teach the agent
project specifics without editing Python.

## Connecting to the daemon (one-time setup)

The page talks to `yuked` on `127.0.0.1:9853`. Two things must be true, exactly as for any browser
client:

1. **The daemon must admit this origin.** It gates `/identity` and the WebSocket upgrade by browser
   origin. Add the docs origin to `~/.config/yuke/yuked.js` and reload the daemon (config is read at
   startup):

   ```js
   import { defineConfig } from "yuke:daemon"
   export default defineConfig({
     allowedOrigins: ["http://127.0.0.1:8765"],   // match the port serve.py prints
   })
   ```

   ```sh
   yuke service stop && yuke service start
   ```

2. **The daemon must be enrolled and hold a credential**, so it can actually run a model — log in
   once (`yuke login`) and configure a default model in `yuked.js`. If the chat can't reach the
   daemon or the origin is refused, the panel says so under the header.

The SDK is vendored under `vendor/yuke/` (copied from `yuke-ts-sdk`'s `dist/`, relay path omitted).
It is loaded with a dynamic `import()`, so pages keep working with no build step; re-vendor it when
the SDK changes.

## Hot reload

The server watches every `docs-html` file and pushes a reload over Server-Sent Events (`/api/watch`).
Edit a page in your editor or let the agent rewrite it — the open browser tab reloads itself the
moment the file changes. The panel's open state survives via `sessionStorage`; the transcript comes
back because the daemon session is re-attached and resynced on load.

## What is here

The landing page plus a single walkthrough:

| Page | Covers |
| --- | --- |
| `index.html` | Landing page: live `cloc` stats and a directory of every page |
| `front_door.html` | The HTTP front door: routing, admission-before-auth, the routes |

The nav on every page and the page list on `index.html` are both auto-discovered from
`docs-html/` — write a new `.html` file under `docs-html/` and it shows up on the next load (the
live reload even refreshes the index tab automatically). Everything else is built on demand — open
the code guide (**✦ ask**) and ask it to add a page. It reads the live source, copies
`front_door.html` as the template, and writes the new page under `docs-html/` (hot reload shows it
at once). It also removes pages that no longer match reality.

## Code is read live, prose is not

Pages carry **no copy of the source**. Each code block names a file and a declaration, and
`serve.py` reads it out of the working tree on request — so an excerpt is always current (Odin and
JS excerpts are syntax-highlighted client-side), and a renamed or deleted declaration renders as a
red error instead of a stale quote. The `index.html` stats come from `cloc --vcs=git`, not hardcoded
numbers.

The prose around those blocks is a snapshot and **will** go stale.

## Policy: delete, do not edit

These files are disposable. When a page stops matching reality:

**Delete it.** `rm docs-html/<page>.html` — then ask the code guide to regenerate it from the current
code (it can also delete the file itself, scoped to `docs-html/`).

Do not hand-patch a page to keep it alive, and do not ask Claude to edit one unless you say so
explicitly. A half-corrected map is worse than no map: it reads as verified when it is not.
Regeneration is cheap; trust in a stale page is not.

Deleting the whole directory is fine and loses nothing that matters.

## Adding a page

Copy any page's `<head>` (it loads the Tailwind CDN and `app.js`) and its `<nav>` (the `<div
class="nav-links">` placeholder is filled by `app.js` from `/api/pages` — leave it empty), style
the prose with Tailwind utilities like the rest of the set, then drop in the two block forms:

```html
<div class="src" data-file="src/daemon/pump.odin" data-decl="broadcast"></div>
<div class="src" data-file="src/daemon/pump.odin" data-start="34" data-end="60"></div>
```

Prefer `data-decl`. It survives edits above it, and the server reports the declaration's real
current line numbers. `data-start`/`data-end` drift silently and should be a last resort.

`serve.py` finds a declaration by matching `name ::` or `name :=` at column 0 and reading to the
next line beginning with `}`, which `odinfmt` guarantees for top-level declarations. Doc comments
and attributes directly above it come along.

To surface live stats on a new page, add `<div id="stats-kpis"></div>` and/or
`<div class="scroll" id="stats-files"></div>`; `app.js` fills them from `/api/stats`.
