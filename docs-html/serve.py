# /// script
# requires-python = ">=3.11"
# ///
"""Serve docs-html, resolve Odin declarations live, and run cloc stats.

The pages carry no code of their own: every block names a file and a declaration,
and this server reads the current source to answer it. A renamed or deleted
declaration renders as a visible error instead of a stale excerpt.

The code-guide chat is no longer served here: the page talks straight to a local
`yuked` daemon through the vendored yuke SDK. This server furnishes only the
system prompt and repo path the page hands to `session.create` (`/api/guide`), so
`context.md` stays live-editable without a daemon restart.

Run it with uv:

    uv run docs-html/serve.py         # http://127.0.0.1:8765/
    uv run docs-html/serve.py 9000    # another port

Endpoints:
    /api/decl, /api/lines   read source out of the working tree
    /api/stats              `cloc --vcs=git` over the repo, parsed to JSON
    /api/guide              repo path + the code-guide system prompt for session.create
    /api/watch              Server-Sent Events reload signal when docs-html files change
"""

import http.server
import json
import os
import subprocess
import sys
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_PORT = 8765

# Lines carried along with a declaration when they sit directly above it.
LEADERS = ("//", "@(")

# cloc is not cheap on a large tree; hold the parsed result briefly.
STATS_TTL = 15.0
TOP_FILES = 16


def repo_file(rel):
    path = os.path.normpath(os.path.join(REPO, rel))
    if not path.startswith(REPO + os.sep) or not os.path.isfile(path):
        return None

    return path


def list_pages():
    # The index page's first job is to show what pages exist. The dynamic nav on every page reads
    # this same list so a page added by the agent shows up everywhere, not just on the index.
    # `index.html` sorts first always — it's the site root, and "index ▸ front door" reads better
    # than "front door ▸ index". The rest is alphabetical.
    pages = []
    for name in os.listdir(HERE):
        if not name.endswith(".html"):
            continue
        if not os.path.isfile(os.path.join(HERE, name)):
            continue
        stem = name[:-5]
        title = stem.replace("_", " ").replace("-", " ")
        pages.append({"file": name, "name": stem, "title": title})
    pages.sort(key=lambda p: (p["file"] != "index.html", p["file"]))

    return pages


def read_lines(rel):
    path = repo_file(rel)
    if path is None:
        return None
    with open(path, encoding="utf-8") as handle:
        return handle.read().split("\n")


def decl_start(lines, name):
    for i, line in enumerate(lines):
        if line.startswith(name + " ::") or line.startswith(name + " :="):
            return i

    return None


def decl_end(lines, start):
    if "{" not in lines[start] and not lines[start].rstrip().endswith("("):
        return start

    for j in range(start + 1, len(lines)):
        if lines[j] == "}" or lines[j].startswith("}"):
            return j

    return len(lines) - 1


def decl_leaders(lines, start):
    first = start
    while first > 0 and lines[first - 1].startswith(LEADERS):
        first -= 1

    return first


def find_decl(rel, name, leaders):
    lines = read_lines(rel)
    if lines is None:
        return {"error": "no such file: " + rel}

    start = decl_start(lines, name)
    if start is None:
        return {"error": "no declaration named " + name + " in " + rel}

    end = decl_end(lines, start)
    if leaders:
        start = decl_leaders(lines, start)

    return {"file": rel, "start": start + 1, "end": end + 1, "code": "\n".join(lines[start:end + 1])}


def find_lines(rel, start, end):
    lines = read_lines(rel)
    if lines is None:
        return {"error": "no such file: " + rel}
    if start < 1 or end > len(lines) or start > end:
        return {"error": "%s has no lines %d-%d" % (rel, start, end)}

    return {"file": rel, "start": start, "end": end, "code": "\n".join(lines[start - 1:end])}


# ---------- stats (cloc --vcs=git) ----------

_stats = {"at": 0.0, "data": None}


def compute_stats():
    try:
        out = subprocess.run(
            ["cloc", "--vcs=git", "--by-file-by-lang", "--json", "--quiet"],
            cwd=REPO, capture_output=True, text=True, timeout=90,
        )
    except FileNotFoundError:
        return {"error": "cloc is not installed — `brew install cloc` (or your package manager)"}
    except subprocess.TimeoutExpired:
        return {"error": "cloc timed out"}

    if out.returncode != 0 or not out.stdout.strip():
        return {"error": "cloc failed: " + (out.stderr.strip() or "no output")}

    raw = json.loads(out.stdout)
    by_lang = raw.get("by_lang", {})
    by_file = raw.get("by_file", {})

    total = by_lang.get("SUM", {})
    languages = []
    for name, v in by_lang.items():
        if name == "SUM":
            continue
        languages.append({
            "language": name,
            "nFiles": v.get("nFiles", 0),
            "code": v.get("code", 0),
            "comment": v.get("comment", 0),
            "blank": v.get("blank", 0),
        })
    languages.sort(key=lambda x: -x["code"])

    files = []
    for path, v in by_file.items():
        if path in ("header", "SUM"):
            continue
        files.append({
            "file": path[2:] if path.startswith("./") else path,
            "language": v.get("language", ""),
            "code": v.get("code", 0),
            "comment": v.get("comment", 0),
        })
    files.sort(key=lambda x: -x["code"])

    return {
        "sum": {
            "code": total.get("code", 0),
            "comment": total.get("comment", 0),
            "blank": total.get("blank", 0),
            "nFiles": total.get("nFiles", 0),
        },
        "languages": languages,
        "files": files[:TOP_FILES],
    }


def stats(refresh):
    now = time.monotonic()
    if refresh or _stats["data"] is None or now - _stats["at"] > STATS_TTL:
        _stats["data"] = compute_stats()
        _stats["at"] = now

    return _stats["data"]


# ---------- code-guide system prompt (handed to the daemon at session.create) ----------

SYSTEM_PROMPT = """You are the documentation author for `yuke-odin` — an Odin implementation of the
yuke wire protocol. Your job is to BUILD and MAINTAIN a small documentation site (the `docs-html/`
pages) that explains this codebase: how it works, how data and control flow move end to end. You
ground every page in the real source and keep the set current. You work live — the reader's browser
hot-reloads the instant you write a file, so a page you create or edit appears immediately.

Right now the site has its landing page (`index.html`) plus `front_door.html`. Build the rest out as
asked.

Repository layout (read it to understand; cite it in the docs):
- `src/wire/` — the authoritative wire representation: types, JSON encode/decode, validation, and the
  method and broadcast registries. The protocol sets are closed; never invent methods, broadcasts,
  union arms, or fields.
- `src/daemon/` — the `yuked` daemon: transports, the frame switch, the session engine, the pump,
  and the SQLite event store.
- `src/js/` — the shared QuickJS host (`yuke:fs` / `yuke:exec` / `yuke:diff`) embedded by both binaries.
- `src/tui/` — the `yuke` interactive client (package `tui`).

Load-bearing invariants (confirm against the source before relying on them):
- One `core:nbio` event loop drives everything; the daemon submits ops and never runs the loop. Two
  worker thread pools are the only other threads and may not log, answer a request, or touch the
  connection table.
- `pump.odin` is the only fan-out and the only sequence authority: durable payloads are stamped,
  encoded once, committed, and then delivered.
- Tickets, not pointers: async work holds a monotonic `Conn_Ticket`, never a `^Conn`.
- Clone at the frame boundary: anything outliving its handler is cloned; the frame arena is reset and
  wiped when `handle_text` returns.
- Assert or handle, never both: peer input returns a `Validation_Error` and degrades; internal state
  asserts and dies at the violation site.

How the pages work:
- Each page is a standalone HTML file under `docs-html/`. Copy `front_door.html` as your template: its
  <head> loads the Tailwind Play CDN and `app.js`, and it opens with a top <nav> containing a
  `<div class="nav-links">` placeholder. Keep that head and that nav shape; style prose with Tailwind
  utilities like it does.
- Pages carry NO copy of the source. A code block is
  `<div class="src" data-file="src/daemon/pump.odin" data-decl="broadcast"></div>` (or
  `data-start`/`data-end`); `serve.py` reads the current source and `app.js` fills it in,
  syntax-highlighted. Prefer `data-decl` — it survives edits above it and reports real line numbers.
  Use declaration names that actually exist (search the source first); a bad name renders red.
- The prose you write around the blocks IS a snapshot and will go stale — keep it tight and factual.
- Nav and the index page list are AUTOMATIC: every page's `<nav class="top">` has a
  `<div class="nav-links">` placeholder that `app.js` fills from `/api/pages` on every load. The
  landing page (`index.html`) also has `<div data-pages-list></div>` that fills with a card grid
  showing the same list. To add a page, just write the file under `docs-html/` — the nav and the
  index pick it up the moment the page is hit (the live reload even refreshes the index tab
  automatically). To retire a page, delete the file. A static `<a>` in the nav is supported as a
  fallback but rarely needed.
- Optional live stats: a page with `<div id="stats-kpis"></div>` and/or
  `<div class="scroll" id="stats-files"></div>` gets `cloc` numbers filled by `app.js`.

Editing scope — IMPORTANT:
- You may create, edit, and DELETE files, but ONLY under `docs-html/`. The source tree is read-only to
  you: read and search anywhere, but never write to or delete anything outside `docs-html/`.
- These pages are disposable. Prefer regenerating a drifted page over hand-patching it, and DELETE a
  page (remove the file and its nav links) that no longer matches reality rather than leaving a
  half-correct map that reads as verified when it is not.

Answering:
- You can also just answer questions about the code — ground every claim in the source and cite
  concrete `path:line`.
- You CANNOT drive the reader's browser or highlight blocks — there is no tool for it. Name the exact
  `path:line`, and the page + anchor to open.

Be concise and concrete."""


def system_prompt():
    # The session is rooted at docs-html (so its sessions stay separate from the reader's own repo
    # work), but the code lives in the parent repo. Give the model both absolute paths; the daemon's
    # file tools take absolute paths, and citations to the reader stay repo-relative.
    workspace_note = (
        "\n\nWorkspace: your session is rooted at " + HERE + " (the docs). The yuke-odin repository "
        "is its parent, " + REPO + " — read and search source there with absolute paths (e.g. " +
        os.path.join(REPO, "src/daemon/pump.odin") + "). Cite locations to the reader as repo-relative "
        "paths like `src/daemon/pump.odin`. Create, edit, and delete files ONLY under " + HERE +
        "; never modify anything outside it."
    )

    prompt = SYSTEM_PROMPT + workspace_note

    # An optional docs-html/context.md lets the reader add project context without touching Python.
    # Read live on every /api/guide request, so edits take effect on the next new chat.
    extra = os.path.join(HERE, "context.md")
    if os.path.isfile(extra):
        with open(extra, encoding="utf-8", errors="replace") as h:
            text = h.read().strip()
        if text:
            return prompt + "\n\n---\nAdditional project context (from docs-html/context.md):\n\n" + text

    return prompt


def guide():
    # The page hands these to session.create: the workspace root (docs-html, so the session picker
    # only surfaces docs sessions) and the code-guide system prompt. No provider config here — the
    # model and credential live in the daemon.
    return {"workspace": HERE, "repo": REPO, "system_prompt": system_prompt()}


# ---------- live reload ----------

def watched_mtimes():
    snap = {}
    for name in os.listdir(HERE):
        if name.endswith((".html", ".css", ".js")):
            try:
                snap[name] = os.path.getmtime(os.path.join(HERE, name))
            except OSError:
                pass

    return snap


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=HERE, **kwargs)

    def handle(self):
        # Browsers close tabs and abort /api/watch mid-request; a peer reset is not our bug.
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError):
            pass

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/watch":
            self.stream_watch()
            return
        if parsed.path.startswith("/api/"):
            self.send_api(parsed)
            return

        # The pages ship no icon; answering keeps the browser's probe out of the log.
        if parsed.path == "/favicon.ico":
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        super().do_GET()

    def send_api(self, parsed):
        query = urllib.parse.parse_qs(parsed.query)

        if parsed.path == "/api/decl":
            rel = query.get("file", [""])[0]
            name = query.get("name", [""])[0]
            leaders = query.get("leaders", ["1"])[0] != "0"
            payload = find_decl(rel, name, leaders)
        elif parsed.path == "/api/lines":
            rel = query.get("file", [""])[0]
            start = int(query.get("start", ["1"])[0])
            end = int(query.get("end", ["1"])[0])
            payload = find_lines(rel, start, end)
        elif parsed.path == "/api/stats":
            payload = stats(query.get("refresh", ["0"])[0] == "1")
        elif parsed.path == "/api/guide":
            payload = guide()
        elif parsed.path == "/api/pages":
            payload = list_pages()
        else:
            payload = {"error": "unknown endpoint " + parsed.path}

        self.send_json(payload, 404 if "error" in payload else 200)

    def send_json(self, payload, default_status):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(default_status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def stream_watch(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        last = watched_mtimes()
        try:
            while True:
                time.sleep(1.0)
                cur = watched_mtimes()
                if cur != last:
                    diff = [f for f in cur if cur.get(f) != last.get(f)]
                    last = cur
                    self.wfile.write(b"data: " + json.dumps({"changed": diff}).encode() + b"\n\n")
                else:
                    self.wfile.write(b": ping\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return

    def end_headers(self):
        if not self.path.startswith("/api/"):
            self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        # Not args[0]: log_error passes a status, not a request line.
        if self.path.startswith("/api/"):
            return
        super().log_message(fmt, *args)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("docs at http://127.0.0.1:%d/  (sources read live from %s)" % (port, REPO))
    print("chat talks to a local yuked daemon via the yuke SDK (see README)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print()


if __name__ == "__main__":
    main()
