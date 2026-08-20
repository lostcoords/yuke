# TUI design

Decisions from the visual pass and the multi-device pass. Source of truth for look
is `../yuke-client`. Source of truth for wire is `src/wire/`. The TUI code today is
a single local connection and a single open replica (`Host.daemon`, `Host.open_session`).

Visual work (theme, markdown, two-line rows, composer, collapse) does not block
multi-device. Multi-device does not block visual work. They share highlight groups
and the session-row layout.

---

## Identity

Yuke is monochrome. Emphasis is inversion and weight, not hue. `danger` is the only
chroma, and only for errors. Cyan `YukeBrand` and indexed `236`/`238` washes are not
the product.

Palette names match the web tokens (`src/app.css` in yuke-client):

| Token | Role |
| --- | --- |
| ink | page (terminal default, not painted black) |
| surface | user band, composer, tool cards, selected row |
| surface-hi | hover / elevated |
| line | rules, borders |
| fg | primary text; inverted CTA |
| muted | secondary |
| faint | placeholders, timestamps |
| danger | errors only |

### Terminal background and light/dark

Every frame paints `Normal` over the grid (`root.draw`). Today `Normal.bg` is
`"black"`, which covers Ghostty/Kitty. The cell renderer already has
`Ansi_Color.Reset` → SGR 39/49. JS already accepts `"reset"`.

v1: `Normal` uses `fg`/`bg` `"reset"` (or omit bg). Selection is `reverse`, not
indexed 238. Named ANSI 16 colors follow the user's terminal palette. Indexed 256
and truecolor hex do not.

Neovim's model: `'background'` is dark/light; OSC 11 luminance detects it; `hi
Normal guibg=NONE` lets the terminal show through; Visual is often reverse. Yuke
does not query OSC 11 yet. Do not need it for v1. A later layer: OSC 11 → dark vs
light → truecolor surfaces at +8% lightness (Codex). `host_parse_style` defaults
omitted fg to White — a reset theme must set fg to `"reset"` or light terminals
get white-on-cream.

---

## Transcript

### Markdown in JS

`wrapMessage` dumps raw markdown. Render a GFM subset in JS, behind the existing
`rowSource` / wrap cache.

- Parse to blocks once per message (width-independent). Wrap to rows on width.
- Port yuke-client `BlockCache`: only the last block re-parses while streaming.
- Subset: heading, paragraph, list, fence (dim pre, **no** syntax highlight),
  strong/em/inline code, blockquote, hr. Tables as pre or skip.
- Pager today is one `{text, group}` per row. Headings/fences can be whole-line
  groups; inline `**` needs `segments: [{text, group}]`.
- Do not port Prism. Do not re-parse the whole draft per token. If the draft
  hitch is real under QuickJS, the handoff escape hatch is native layout
  (Option 1), not a second JS highlighter.

### User vs assistant

User turn: gutter `⟩` on line 0, continuation muted, surface or reverse — not
ANSI 236. Assistant: rendered markdown, no box. Tools later: collapsible surface
card (verb + target + status), Codex `▌│└` gutter is the fallback if a card is
too heavy.

### Composer

2–3 row box (rounded, `line` / `reset` border), placeholder dim. Context row
above: device · workspace · model. Activity line between transcript and
composer, hidden when idle — copy from `activityLabel` in yuke-client
(`Thinking…` / `Running grep…` / `bash needs approval`). Send/Stop is one
control. Queued inputs as dimmed user bands. Pi's editor box + the web stacking
order (transcript → permission → activity → composer).

---

## Sidebar

Herdr width, yuke-client rows. Not a 28% untitled list.

- Default ~22–26 cols, min 18, max 36. Collapse / hide under ~100 cols.
  `Ctrl+F` stays the session finder. Per-pane footers go away; one root status
  line.
- **Two screen rows per session** (`List` today is 1 cell/item — needs
  `itemHeight = 2`):

  ```
  ●  new chat                    2m
     yuke-odin · grok-4
  ```

  Line 0: status mark (empty slot when idle) + title + relative time.
  Line 1: faint workspace · model; `wants bash` when `waiting_permission`.
  Selected: reverse (or surface) on both rows.

- Title: `session.title` when non-empty, else `"new chat"`. The daemon does not
  set session titles (`session_from_create` leaves `""`). That is a missing
  feature, not a corrupt field. Do not open every session for a first-line
  preview. Workspace title from `workspace.describe` / a small id→title cache
  on that connection. Time from `updated_at_ms`. Status from `activity.state`
  (same three-way as web `sessionStatus`: needs-input / working / idle).

- Inbox buckets later (Needs input / Working / rest), matching the web. v1 can
  be a flat newest-first list as long as the row is two lines and
  cross-device.

---

## Multi-device

The web app is the spec (`../yuke-client/src/App.svelte`). Connect to every
reachable device; the sidebar is live for all of them; a chat pane is bound to
`(connKey, sessionId)`; explorer browse is bound to a `connKey`.

### What exists

| Layer | TUI now | Web |
| --- | --- | --- |
| Connections | One `Daemon_Connection`. Second `connect` throws. | `ControllerPool` |
| Relay | `connect({ remote: true, device })` works. JS never calls it. | Same Path B, browser CSRF |
| Lists | `session.list` on that one socket | `FeedPool` per connection |
| Transcript | One `Open_Session` replica. `sessionOpen` tears the previous down. | `SessionManager` keyed by `connKey + sessionId` |
| Roster | Fetched inside a remote connect, not a JS API | Bootstrap `/browser/devices` |
| Explorer | `workspace.browse` on the one daemon | `WorkspaceExplorer({ connKey })` |
| Splits | `Ctrl+K v/s` inserts a `MainPane` placeholder | Pane tree of real chats |

TUI Path B already uses `yuke login` client identity (`session.json` /
`session.key`) and `GET /api/v1/devices`. Unenrolled: local only.

Reachable set (web `reachableTargets`): local if found, plus every online (or
already-held) roster device with a valid pin, **excluding this machine's roster
row** (local is Path A, never relay-to-self).

### N connections

`Host.daemon` becomes a map keyed like the web: `"local"` / `"remote:<device_id>"`.
Reconcile toward the reachable set (start new, stop left). JS: `devices()`
(roster without connecting), `request(connKey, method, params)`,
`sessionOpen(connKey, id)`. Teardown still closes clients before `js`.

`relay_busy` (4409) is a device client cap — TUI and web compete. Show the web
copy.

### Why N transcripts (not one replica)

One replica was a host convenience. It is the wrong product the moment there is
more than one connection, and the TUI already pretends to have more than one
chat:

- **Splits already exist.** `window:split-right` / `split-down` insert a
  `MainPane` that says "select a session". A one-replica host cannot put two
  live chats on screen. That makes the keymap a lie.
- **The wire already takes a list.** `subscription.set` replaces the subscribed
  set (`[]Session_Id`, cap `LIMITS.max_subscriptions` = 64). The TUI today
  sends a 1-element slice. N mounted chats on one daemon is one set update, not
  a protocol change.
- **The web already reconciles N.** `SessionManager.reconcile(refs)` opens
  exactly the mounted panes and drops the rest. Comment there: "Today the open
  set holds at most the active session … panels will let it hold more — the
  reconcile below supports N." The TUI's pane tree is those panels.
- **Switching must not destroy the other chat.** One replica means
  `sessionOpen` calls `open_session_teardown`: wrap cache, scroll, and the
  streaming draft of the background session are gone. A split or a
  local+remote pair would resync on every focus change.
- **Lists are not transcripts.** N connections without N replicas gives a
  cross-device inbox that cannot open two of those rows at once. That is not
  the web app.

Cost is real and bounded:

- A `Session_Replica` is one session's committed window (capped by
  `max_page_size` = 500) plus the active draft. JS wrap cache is already per
  `Transcript` instance — one `ChatView` per leaf pays it anyway.
- Broadcast routing today asserts `&h.daemon.client == c`. N connections must
  look up the client; N replicas look up `(connKey, session_id)` on that
  client. Same dispatch, one extra map.
- Cap mounted transcripts to the leaves in the node tree (typically 1–4), not
  every inbox row. Sidebar feeds stay `session.list` (cheap). Only **open
  panes** hold a replica, matching the web: "exactly the sessions the panes
  mount are kept open."
- Per connection, `subscription.set` is the union of that connection's mounted
  session ids.

Do not do "N connections, 1 replica" as a stepping stone. The host change is
the map-of-clients; a map-of-replicas is the same change. A switcher that
drops the other socket is not the web app and fights the existing split UI.

### Replica map

Replace `Host.open_session` with entries keyed by `connKey + session_id`
(session ids are per-daemon; the same hex on two devices must not collide).

Each entry: `Session_Replica`, `Sync_State`, `rev`. `sessionOpen(connKey, id)`
inserts (or focuses) without tearing others down. Closing a leaf drops that
entry and re-`subscription.set`s that connection. JS events become
`{ type: "session", connKey, kind, id }` so the right `ChatView` reloads.

A leaf `ChatView` holds `{ connKey, sessionId }` and reads
`sessionOutline(connKey, id)` / `sessionText(connKey, id, messageId)`. Send,
interrupt, and activity go to that pair. Focused leaf owns `Ctrl+C`.

Default layout stays sidebar | one chat. Split clones a new `ChatView` and
opens a session into it (picker or the already-selected row). Closing the last
chat leaf is not allowed (same as today's "lone root cannot close").

### Explorer dropdown

Explorer **defaults to local** (`browseConnKey = "local"`). The picker header
is a device dropdown (local + roster). Changing it resets the path — each
daemon has its own default root. Browse is
`request(browseConnKey, "workspace.browse", …)`. If that key is not connected,
connect it (same as opening a remote chat). Git badges unchanged.

This is why N connections are not optional even for a single chat: you must be
able to browse local while a split (or the focused chat) is on a remote
device. One socket cannot do that.

The dropdown is a connection selector, not a second filesystem. Title/footer
name the device (`local` / enrolled name). Offline / bad-pin devices are
listed and not browsable (`UnavailableReason` on the web).

### Inbox

Rows carry `connKey` so open knows which replica to mount. Two-line row adds
device on the meta line when the list is mixed (`office · yuke-odin · grok-4`),
matching web `SessionRow` `showDevice`. Group-by-device is a later view toggle
(web Inbox / By device).

### Out of scope for this pass

- Daemon-generated session titles.
- OSC 11 truecolor surfaces.
- Syntax highlighting in fences.
- Web pane preview vs permanent tabs / drag-split. TUI splits stay explicit
  (`Ctrl+K v/s`).
- Browser CSRF. TUI stays on the login-session bearer.
- Connecting a bad-pin device.

---

## References

- yuke-client: `src/app.css`, `SessionRow.svelte`, `MessageItem.svelte`,
  `Composer.svelte`, `WorkspaceExplorer.svelte`, `ControllerPool.svelte.ts`,
  `SessionManager.svelte.ts`, `reachability.ts`, `App.svelte`
- TUI now: `src/tui/host.odin` (`daemon`, `open_session`), `src/tui/session.odin`
  (`sessionOpen` tears down the prior replica), `src/tui/relay_connect.odin`,
  `src/tui/js/defaults.js` (sidebar ratio, `ChatView`, splits)
- Wire: `Subscription_Set_Params`, `LIMITS.max_subscriptions` (64)
- Prior notes: `docs/handoff-tui.md` (transcript v2, activity line, collapse)
