// Client for docs-html. Fills every .src block from the live source tree via serve.py,
// renders repo stats from `cloc`, syntax-highlights Odin/JS excerpts, hot-reloads on file
// changes, and drives the code-guide chat sidebar. Styling is Tailwind (Play CDN, JIT) — the
// classes below are emitted into the DOM and compiled in the browser. Nothing here carries
// its own copy of the code, so a renamed declaration shows an error, not a stale excerpt.

function escapeHtml(text) {
  return text.replace(/[&<>]/g, function (c) {
    return c === "&" ? "&amp;" : c === "<" ? "&lt;" : "&gt;";
  });
}

// ---------- syntax highlighting (Odin + JS, no dependencies) ----------

const KEYWORDS = {
  odin: new Set(("package import foreign using when where if else for switch case in " +
    "not_in do break continue fallthrough defer return proc struct enum union bit_set map " +
    "dynamic distinct cast transmute auto_cast typeid any matrix const inline no_inline " +
    "or_return or_else or_break or_continue context nil true false").split(" ")),
  js: new Set(("const let var function return if else for while switch case break continue " +
    "new class extends super this typeof instanceof in of do try catch finally throw async " +
    "await yield import export from default null undefined true false void delete").split(" ")),
};

const ODIN_TYPES = new Set(("int uint uintptr rawptr string cstring rune byte bool b8 b16 b32 b64 " +
  "i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f16 f32 f64 complex32 complex64 complex128 " +
  "quaternion64 quaternion128 quaternion256").split(" "));

const TOK_CLASS = {
  com: "italic text-stone-400 dark:text-stone-500",
  str: "text-emerald-600 dark:text-emerald-400",
  num: "text-amber-600 dark:text-amber-400",
  kw: "text-rose-600 dark:text-rose-400",
  typ: "text-violet-600 dark:text-violet-400",
  fn: "text-sky-600 dark:text-sky-400",
  dir: "text-amber-600 dark:text-amber-400",
};

function langOf(file) {
  if (file.endsWith(".odin")) return "odin";
  if (file.endsWith(".js") || file.endsWith(".mjs") || file.endsWith(".ts")) return "js";
  return null;
}

// Tokenize into {t, v} where v may span newlines (block comments / raw strings).
function tokenize(code, lang) {
  const kw = KEYWORDS[lang];
  const out = [];
  const n = code.length;
  let i = 0;
  const isId = (c) => /[A-Za-z0-9_]/.test(c);

  while (i < n) {
    const c = code[i];
    const two = code.substr(i, 2);

    if (two === "/*") {
      let depth = 1, j = i + 2;
      while (j < n && depth > 0) {
        if (code.substr(j, 2) === "/*") { depth++; j += 2; }
        else if (code.substr(j, 2) === "*/") { depth--; j += 2; }
        else j++;
      }
      out.push({ t: "com", v: code.slice(i, j) }); i = j; continue;
    }
    if (two === "//") {
      let j = i + 2;
      while (j < n && code[j] !== "\n") j++;
      out.push({ t: "com", v: code.slice(i, j) }); i = j; continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      const multiline = c === "`";
      let j = i + 1;
      while (j < n) {
        if (code[j] === "\\") { j += 2; continue; }
        if (code[j] === c) { j++; break; }
        if (!multiline && code[j] === "\n") break;
        j++;
      }
      out.push({ t: "str", v: code.slice(i, j) }); i = j; continue;
    }
    if (/[0-9]/.test(c) || (c === "." && /[0-9]/.test(code[i + 1] || ""))) {
      let j = i;
      while (j < n && /[0-9a-fA-FxXoObB._]/.test(code[j])) j++;
      out.push({ t: "num", v: code.slice(i, j) }); i = j; continue;
    }
    if ((c === "#" || c === "@") && lang === "odin") {
      let j = i + 1;
      while (j < n && isId(code[j])) j++;
      out.push({ t: "dir", v: code.slice(i, j) }); i = j; continue;
    }
    if (/[A-Za-z_]/.test(c)) {
      let j = i;
      while (j < n && isId(code[j])) j++;
      const word = code.slice(i, j);
      let k = j;
      while (k < n && code[k] === " ") k++;
      let t = "id";
      if (kw.has(word)) t = "kw";
      else if (lang === "odin" && (ODIN_TYPES.has(word) || /^[A-Z]/.test(word))) t = "typ";
      else if (lang === "js" && /^[A-Z]/.test(word)) t = "typ";
      else if (code[k] === "(") t = "fn";
      out.push({ t: t, v: word }); i = j; continue;
    }

    out.push({ t: "txt", v: c }); i++;
  }
  return out;
}

function highlightLines(code, lang) {
  if (!lang) return code.split("\n").map(escapeHtml);

  const lines = [];
  let cur = "";
  tokenize(code, lang).forEach(function (tok) {
    const parts = tok.v.split("\n");
    parts.forEach(function (part, idx) {
      if (idx > 0) { lines.push(cur); cur = ""; }
      const html = escapeHtml(part);
      const cls = TOK_CLASS[tok.t];
      cur += cls ? '<span class="' + cls + '">' + html + "</span>" : html;
    });
  });
  lines.push(cur);
  return lines;
}

const SRC_SHELL = "my-5 rounded-xl border border-stone-200 dark:border-stone-800 overflow-hidden " +
  "bg-stone-100/60 dark:bg-stone-900/50";
const SRC_BAR = "flex items-center justify-between gap-3 px-3.5 py-2 bg-stone-100 dark:bg-stone-900 " +
  "border-b border-stone-200 dark:border-stone-800 font-mono text-xs text-stone-500";

function renderCode(block, payload) {
  block.className = "src " + SRC_SHELL;
  const html = highlightLines(payload.code, langOf(payload.file));
  const body = html
    .map(function (line, i) {
      return '<span class="inline-block w-[3.5em] pr-4 text-right text-stone-400/70 select-none">' +
        (payload.start + i) + '</span><span class="whitespace-pre">' + line + "</span>";
    })
    .join("\n");

  const decl = block.dataset.decl
    ? '<b class="text-stone-800 dark:text-stone-100 font-semibold">' + escapeHtml(block.dataset.decl) + "</b> in "
    : "";
  block.innerHTML =
    '<div class="' + SRC_BAR + '"><span class="text-stone-600 dark:text-stone-300">' +
    decl + escapeHtml(payload.file) +
    '</span><span class="whitespace-nowrap">' + payload.start + "–" + payload.end + "</span></div>" +
    '<pre class="m-0 py-3 overflow-x-auto font-mono text-[12.5px] leading-relaxed text-stone-800 dark:text-stone-200">' +
    body + "</pre>";
}

function renderFailure(block, message) {
  block.className = "src " + SRC_SHELL;
  block.innerHTML =
    '<div class="' + SRC_BAR + '"><span>' + escapeHtml(block.dataset.file || "?") +
    '</span><span class="text-rose-500">unresolved</span></div>' +
    '<div class="px-4 py-3 font-mono text-xs text-rose-600 dark:text-rose-400 bg-rose-50 dark:bg-rose-950/40">' +
    escapeHtml(message) + "</div>";
}

function blockUrl(block) {
  const file = encodeURIComponent(block.dataset.file);
  if (block.dataset.decl) {
    return "/api/decl?file=" + file + "&name=" + encodeURIComponent(block.dataset.decl);
  }

  return "/api/lines?file=" + file + "&start=" + block.dataset.start + "&end=" + block.dataset.end;
}

function load(block) {
  block.className = "src " + SRC_SHELL;
  block.innerHTML = '<div class="px-4 py-3 font-mono text-xs text-stone-500">reading ' +
    escapeHtml(block.dataset.file) + " …</div>";

  fetch(blockUrl(block))
    .then(function (response) { return response.json(); })
    .then(function (payload) {
      if (payload.error) {
        renderFailure(block, payload.error + " — the source moved; this page needs regenerating");
        return;
      }
      renderCode(block, payload);
    })
    .catch(function () {
      renderFailure(block, "no source server — run: uv run docs-html/serve.py");
    });
}

// ---------- stats (cloc --vcs=git) ----------

function fmtK(n) {
  return n >= 1000 ? (n / 1000).toFixed(n >= 10000 ? 0 : 1) + "k" : String(n);
}

const KPI_CARD = "rounded-xl border border-stone-200 dark:border-stone-800 bg-white dark:bg-stone-900 px-4 py-3.5";

function renderStats(data) {
  const kpis = document.getElementById("stats-kpis");
  const filesEl = document.getElementById("stats-files");
  if (!kpis && !filesEl) return;

  if (data.error) {
    if (kpis) kpis.innerHTML = '<div class="' + KPI_CARD + ' text-sm text-stone-500">' + escapeHtml(data.error) + "</div>";
    return;
  }

  if (kpis) {
    const odin = (data.languages || []).filter(function (l) { return l.language === "Odin"; })[0];
    const cells = [{ n: fmtK(data.sum.code), l: "lines of code, " + data.sum.nFiles + " files" }];
    if (odin) cells.push({ n: fmtK(odin.code), l: "in Odin (" + odin.nFiles + " files)" });
    cells.push({ n: fmtK(data.sum.comment), l: "lines of comments" });
    cells.push({ n: String((data.languages || []).length), l: "languages" });
    kpis.innerHTML = cells
      .map(function (c) {
        return '<div class="' + KPI_CARD + '"><div class="font-mono text-2xl font-semibold tracking-tight text-stone-900 dark:text-stone-50">' +
          c.n + '</div><div class="text-xs text-stone-500 mt-1">' + c.l + "</div></div>";
      })
      .join("");
  }

  if (filesEl) {
    const rows = (data.files || [])
      .map(function (f) {
        return '<tr class="border-b border-stone-200 dark:border-stone-800 last:border-0">' +
          '<td class="py-2.5 px-4 font-mono text-[12.5px] text-stone-700 dark:text-stone-300">' + escapeHtml(f.file) + "</td>" +
          '<td class="py-2.5 px-4 text-sm text-stone-500">' + escapeHtml(f.language) + "</td>" +
          '<td class="py-2.5 px-4 font-mono text-[12.5px] text-right text-stone-700 dark:text-stone-300">' + f.code + "</td></tr>";
      })
      .join("");
    filesEl.innerHTML =
      '<table class="w-full text-sm"><thead><tr class="bg-stone-100 dark:bg-stone-900 text-stone-500">' +
      '<th class="py-2.5 px-4 text-left font-semibold text-[11px] uppercase tracking-wider">File</th>' +
      '<th class="py-2.5 px-4 text-left font-semibold text-[11px] uppercase tracking-wider">Language</th>' +
      '<th class="py-2.5 px-4 text-right font-semibold text-[11px] uppercase tracking-wider">code</th>' +
      "</tr></thead><tbody>" + rows + "</tbody></table>";
  }
}

function loadStats() {
  if (!document.getElementById("stats-kpis") && !document.getElementById("stats-files")) return;
  fetch("/api/stats")
    .then(function (r) { return r.json(); })
    .then(renderStats)
    .catch(function () { renderStats({ error: "no source server — run: uv run docs-html/serve.py" }); });
}

// ---------- hot reload ----------

function liveReload() {
  if (!window.EventSource) return;
  const here = location.pathname.split("/").pop() || "index.html";
  const es = new EventSource("/api/watch");
  es.onmessage = function (ev) {
    let data;
    try { data = JSON.parse(ev.data); } catch (e) { return; }
    const changed = data.changed || [];
    // On the index page, any new or removed page should refresh the page list — so reload on any
    // .html change. On other pages, only the current page (or app.js) should trigger a reload.
    const onIndex = here === "index.html";
    const pageAdded = changed.some(function (f) { return f.endsWith(".html"); });
    if (changed.indexOf(here) >= 0 || changed.indexOf("app.js") >= 0 ||
        (onIndex && pageAdded)) {
      location.reload();
    }
  };
}

// ---------- paginated index (cards on the landing page) ----------
//
// The landing page renders the same page list as a card grid. Skipping `index.html` is the index's
// only page-specific decision — the rest is the same data as the nav.

const PAGE_CARD = "group block rounded-xl border border-stone-200 dark:border-stone-800 bg-white " +
  "dark:bg-stone-900 px-4 py-3.5 hover:border-amber-500 dark:hover:border-amber-500 " +
  "hover:bg-amber-500/5 transition-colors";

function populatePagesList() {
  const containers = document.querySelectorAll("[data-pages-list]");
  if (!containers.length) return Promise.resolve();
  const here = location.pathname.split("/").pop() || "index.html";

  return fetch("/api/pages")
    .then(function (r) { return r.json(); })
    .then(function (pages) {
      const html = (pages || [])
        .filter(function (p) { return p.file !== here; })
        .map(function (p) {
          return '<a href="' + escapeAttr(p.file) + '" class="' + PAGE_CARD + '">' +
            '<div class="font-semibold text-[15px] text-stone-900 dark:text-stone-100 group-hover:text-amber-700 dark:group-hover:text-amber-400">' +
            escapeHtml(p.title) + '</div>' +
            '<div class="mt-1 font-mono text-[11px] text-stone-400">' +
            escapeHtml(p.file) + '</div></a>';
        }).join("");
      containers.forEach(function (container) { container.innerHTML = html; });
    })
    .catch(function () { /* offline → empty list */ });
}

// ---------- nav (auto-filled from /api/pages) ----------
//
// Pages declare a `<div class="nav-links"></div>` inside `nav.top`; this helper fills in one
// <a> per page from the server, with the current page highlighted. Pages added by the agent show
// up here as soon as the file lands — no manual nav edits anywhere.

const NAV_LINK_BASE = "rounded-md px-2.5 py-1.5 font-mono text-[13px] text-stone-500 " +
  "hover:bg-stone-200/60 dark:hover:bg-stone-800/60 hover:text-stone-800 dark:hover:text-stone-100";
const NAV_LINK_ACTIVE = "rounded-md px-2.5 py-1.5 font-mono text-[13px] bg-amber-500/15 " +
  "text-amber-700 dark:text-amber-400";

function populateNav() {
  const containers = document.querySelectorAll("nav.top .nav-links");
  if (!containers.length) return Promise.resolve();
  const here = location.pathname.split("/").pop() || "index.html";

  return fetch("/api/pages")
    .then(function (r) { return r.json(); })
    .then(function (pages) {
      const html = (pages || []).map(function (p) {
        const cls = p.file === here ? NAV_LINK_ACTIVE : NAV_LINK_BASE;
        return '<a href="' + escapeAttr(p.file) + '" class="' + cls + '">' +
          escapeHtml(p.title) + "</a>";
      }).join("");
      containers.forEach(function (container) { container.innerHTML = html; });
    })
    .catch(function () { /* offline → empty nav */ });
}

// ---------- markdown (dependency-free, escapes first) ----------

// Inline formatting on already-escaped text: code spans, links, bold, italic.
function mdInline(s) {
  const codes = [];
  s = s.replace(/`([^`]+)`/g, function (_, c) { codes.push(c); return " " + (codes.length - 1) + " "; });
  s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, function (_, t, u) {
    if (!/^(https?:\/\/|\/|#|\.)/.test(u)) return t;
    return '<a class="text-amber-600 dark:text-amber-400 underline" target="_blank" rel="noopener" href="' +
      u.replace(/"/g, "%22") + '">' + t + "</a>";
  });
  s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/__([^_]+)__/g, "<strong>$1</strong>");
  s = s.replace(/(^|[^*\w])\*([^*\n]+)\*/g, "$1<em>$2</em>");
  s = s.replace(/(^|[^_\w])_([^_\n]+)_/g, "$1<em>$2</em>");
  s = s.replace(/ (\d+) /g, function (_, i) {
    return '<code class="rounded bg-stone-200/70 dark:bg-stone-800 px-1 py-0.5 font-mono text-[0.85em]">' + codes[+i] + "</code>";
  });
  return s;
}

const MD_PRE = 'my-1 overflow-x-auto rounded-lg border border-stone-200 dark:border-stone-800 ' +
  'bg-stone-100 dark:bg-stone-950 p-2.5 font-mono text-[12px] leading-relaxed';
const LIST_BLOCK = /^\s*([-*+]|\d+[.)])\s+/;

function renderMarkdown(src) {
  const lines = String(src).replace(/\r\n?/g, "\n").split("\n");
  const out = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];
    const fence = line.match(/^```(\w+)?\s*$/);
    if (fence) {
      const raw = (fence[1] || "").toLowerCase();
      const lang = raw === "odin" ? "odin" : (raw === "js" || raw === "javascript" || raw === "ts" || raw === "typescript") ? "js" : null;
      const buf = [];
      i++;
      while (i < lines.length && !/^```\s*$/.test(lines[i])) { buf.push(lines[i]); i++; }
      i++;
      const code = buf.join("\n");
      const body = lang ? highlightLines(code, lang).join("\n") : escapeHtml(code);
      out.push('<pre class="' + MD_PRE + '"><code>' + body + "</code></pre>");
      continue;
    }
    if (/^\s*$/.test(line)) { i++; continue; }

    const h = line.match(/^(#{1,6})\s+(.*)$/);
    if (h) {
      const size = h[1].length <= 1 ? "text-base" : h[1].length === 2 ? "text-[15px]" : "text-sm";
      out.push('<div class="' + size + ' font-semibold text-stone-900 dark:text-stone-100">' + mdInline(escapeHtml(h[2])) + "</div>");
      i++; continue;
    }
    if (LIST_BLOCK.test(line)) {
      const ordered = /^\s*\d+[.)]\s+/.test(line);
      const items = [];
      while (i < lines.length && LIST_BLOCK.test(lines[i])) { items.push(lines[i].replace(LIST_BLOCK, "")); i++; }
      const tag = ordered ? "ol" : "ul";
      out.push('<' + tag + ' class="' + (ordered ? "list-decimal" : "list-disc") + ' pl-5 space-y-0.5">' +
        items.map(function (it) { return "<li>" + mdInline(escapeHtml(it)) + "</li>"; }).join("") + "</" + tag + ">");
      continue;
    }
    if (/^\s*>\s?/.test(line)) {
      const buf = [];
      while (i < lines.length && /^\s*>\s?/.test(lines[i])) { buf.push(lines[i].replace(/^\s*>\s?/, "")); i++; }
      out.push('<blockquote class="border-l-2 border-stone-300 dark:border-stone-700 pl-3 text-stone-500">' +
        mdInline(escapeHtml(buf.join(" "))) + "</blockquote>");
      continue;
    }

    const buf = [];
    while (i < lines.length && !/^\s*$/.test(lines[i]) && !/^```/.test(lines[i]) &&
      !/^(#{1,6})\s/.test(lines[i]) && !LIST_BLOCK.test(lines[i]) && !/^\s*>\s?/.test(lines[i])) {
      buf.push(lines[i]); i++;
    }
    out.push("<p>" + mdInline(escapeHtml(buf.join("\n")).replace(/\n/g, "<br>")) + "</p>");
  }
  return out.join("");
}

// ---------- chat sidebar (a live yuke session) ----------
//
// The chat is a real `yuked` session, not a server-side proxy: the page connects straight to the
// local daemon with the vendored yuke SDK (vendor/yuke), creates a yolo session rooted at this repo,
// and streams the turn from broadcasts. serve.py furnishes only the system prompt + repo path
// (/api/guide); the model, provider, and credential all live in the daemon. The session id survives
// a hot reload (sessionStorage) — on reload we re-attach and resync, so the transcript comes back.

const OPEN_KEY = "yuke-docs-chat";       // panel open flag, per tab (sessionStorage)
const SESSION_KEY = "yuke-docs-session"; // daemon session id, durable across restarts (localStorage)
const DAEMON_HOST = "127.0.0.1";
const DAEMON_PORT = 9853;
const CLIENT_IDENTITY = { name: "yuke-docs", version: "0.1.0" };

// The SDK is ESM; import it lazily so pages without the panel open pay nothing.
let sdkPromise = null;
function sdk() {
  if (!sdkPromise) sdkPromise = import("./vendor/yuke/index.js");

  return sdkPromise;
}

// One shared daemon connection for the tab. Cleared on close/error so the next attach reconnects.
let clientPromise = null;
function daemonClient() {
  if (!clientPromise) {
    clientPromise = (async function () {
      const yuke = await sdk();
      const endpoint = await yuke.discoverDaemon({ host: DAEMON_HOST, port: DAEMON_PORT });
      const url = (endpoint && endpoint.wsUrl) || ("ws://" + DAEMON_HOST + ":" + DAEMON_PORT + "/ws");

      return yuke.Client.connect(url, { client: CLIENT_IDENTITY });
    })();
    clientPromise.catch(function () { clientPromise = null; });
  }

  return clientPromise;
}

// The workspace root + system prompt for session.create; fetched once, cached for the tab.
let guidePromise = null;
function guideInfo() {
  if (!guidePromise) {
    guidePromise = fetch("/api/guide").then(function (r) { return r.json(); });
    guidePromise.catch(function () { guidePromise = null; });
  }

  return guidePromise;
}

// Chosen model, remembered so it is the default for the next new session. Empty means the daemon's
// configured default (omit `model` on create).
const MODEL_KEY = "yuke-docs-model";
function savedModel() {
  try { return localStorage.getItem(MODEL_KEY) || ""; } catch (e) { return ""; }
}
function rememberModel(id) {
  try { if (id) localStorage.setItem(MODEL_KEY, id); else localStorage.removeItem(MODEL_KEY); } catch (e) { /* ignore */ }
}

// The model catalog, revision-cached: `catalog.list` returns "full" (models + rev) or "unchanged"
// (rev only) against the rev we hold, so re-opening is a cheap round-trip that keeps the models.
let catalogCache = { rev: null, models: [] };
async function loadModels() {
  const client = await daemonClient();
  const result = await client.request("catalog.list", catalogCache.rev ? { since_rev: catalogCache.rev } : {});
  if (result.type === "full") catalogCache = { rev: result.catalog_rev, models: result.models };
  else catalogCache = { rev: result.catalog_rev, models: catalogCache.models };

  return catalogCache.models;
}

function escapeAttr(s) {
  return escapeHtml(s).replace(/"/g, "&quot;");
}

// A short local timestamp for the session picker. Sessions here all share the workspace-derived
// title ("docs-html"), so time + message count is what actually distinguishes them.
function formatWhen(ms) {
  if (!ms) return "";
  return new Date(ms).toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
}

// Models grouped into <optgroup> by provider, providers and models each name-sorted.
function modelOptionsHtml(models, selectedId) {
  const byProvider = {};
  models.forEach(function (m) { (byProvider[m.provider] = byProvider[m.provider] || []).push(m); });

  return Object.keys(byProvider).sort().map(function (provider) {
    const opts = byProvider[provider]
      .slice()
      .sort(function (a, b) { return a.name.localeCompare(b.name); })
      .map(function (m) {
        return '<option value="' + escapeAttr(m.id) + '"' + (m.id === selectedId ? " selected" : "") + ">" +
          escapeHtml(m.name) + "</option>";
      })
      .join("");

    return '<optgroup label="' + escapeAttr(provider) + '">' + opts + "</optgroup>";
  }).join("");
}

// The session id is durable (localStorage) so the daemon session continues across a full restart,
// not only a hot reload; the open flag is per-tab (sessionStorage).
function chatState() {
  let open = false;
  try { open = JSON.parse(sessionStorage.getItem(OPEN_KEY) || "false") === true; } catch (e) { open = false; }
  let sessionId = null;
  try { sessionId = localStorage.getItem(SESSION_KEY) || null; } catch (e) { sessionId = null; }

  return { open: open, sessionId: sessionId };
}

function saveChat(state) {
  try { sessionStorage.setItem(OPEN_KEY, JSON.stringify(!!state.open)); } catch (e) { /* ignore */ }
  try {
    if (state.sessionId) localStorage.setItem(SESSION_KEY, state.sessionId);
    else localStorage.removeItem(SESSION_KEY);
  } catch (e) { /* ignore */ }
}

// ---- transcript projection: replica state → renderable views ----

function textOfParts(content, kind) {
  return content
    .filter(function (p) { return p.type === kind; })
    .map(function (p) { return p.text; })
    .join("");
}

function toolSteps(content) {
  return content
    .filter(function (p) { return p.type === "tool"; })
    .map(function (p) { return { tool: p.name, args: p.arguments, state: p.state && p.state.type }; });
}

function messageView(m) {
  if (m.type === "user") return { role: "user", text: textOfParts(m.content, "text") };
  if (m.type === "assistant") return { role: "assistant", text: textOfParts(m.content, "text"), steps: toolSteps(m.content) };
  if (m.type === "compaction") return { role: "system", text: "— context compacted —" };

  return null;
}

// The in-flight assistant draft: parts are ordinal (Part_Id), so index 0..part_count-1.
function activeView(replica) {
  const info = replica.activeInfo();
  if (!info) return null;

  let text = "";
  const steps = [];
  for (let i = 0; i < info.part_count; i++) {
    const kind = replica.partKind(i);
    if (kind === "text") text += replica.partText(i) || "";
    else if (kind === "tool") {
      const tp = replica.toolPart(i);
      if (tp) steps.push({ tool: tp.name, args: tp.arguments, state: tp.state && tp.state.type });
    }
  }

  return { role: "assistant", text: text, steps: steps, active: true };
}

function stepLine(steps) {
  return steps
    .map(function (s) {
      let a = {};
      try { a = JSON.parse(s.args || "{}"); } catch (e) { a = {}; }
      const arg = a.path || a.pattern || a.file || a.command || a.query || "";
      const running = s.state && s.state !== "completed" ? " · " + s.state : "";
      return s.tool + (arg ? "(" + arg + ")" : "") + running;
    })
    .join("  ·  ");
}

const ROLE_LABEL = { user: "you", assistant: "code guide", system: "system" };

function bubbleHtml(v) {
  const suffix = v.pending ? " · sending…" : v.active && !v.text ? " · thinking…" : "";
  const who = '<div class="font-mono text-[10px] uppercase tracking-wider text-stone-400 mb-1">' +
    (ROLE_LABEL[v.role] || v.role) + suffix + "</div>";

  let body;
  if (v.role === "assistant") {
    body = v.text
      ? '<div class="text-sm break-words text-stone-800 dark:text-stone-100 space-y-2 leading-relaxed">' +
        renderMarkdown(v.text) + "</div>"
      : "";
  } else {
    const cls = v.role === "user"
      ? "text-sm whitespace-pre-wrap break-words bg-amber-500/10 text-stone-800 dark:text-stone-100 px-3 py-2 rounded-xl" +
        (v.pending ? " opacity-60" : "")
      : "text-sm italic text-stone-400";
    body = '<div class="' + cls + '">' + escapeHtml(v.text) + "</div>";
  }

  const steps = v.steps && v.steps.length
    ? '<div class="mt-1.5 font-mono text-[11px] text-stone-400 border-l-2 border-stone-200 dark:border-stone-700 pl-2">' +
      escapeHtml(stepLine(v.steps)) + "</div>"
    : "";

  return '<div>' + who + body + steps + "</div>";
}

function buildChat() {
  const state = chatState();

  const root = document.createElement("div");
  root.innerHTML =
    '<button class="chat-fab fixed right-5 bottom-5 z-40 rounded-full border border-amber-500 bg-amber-500 ' +
    'px-4 py-2.5 font-mono text-[13px] font-semibold text-white shadow-lg shadow-black/20 hover:brightness-105">✦ ask</button>' +
    '<aside class="chat-panel fixed right-0 top-0 z-40 h-screen w-[min(420px,100vw)] translate-x-full ' +
    'transition-transform duration-200 flex flex-col border-l border-stone-200 dark:border-stone-800 ' +
    'bg-white dark:bg-stone-900 shadow-2xl shadow-black/30">' +
    '<div class="flex items-center justify-between px-4 py-3 border-b border-stone-200 dark:border-stone-800 ' +
    'bg-stone-100 dark:bg-stone-950 font-mono text-[11px] uppercase tracking-wider text-stone-500">' +
    '<span>code guide</span><span class="flex items-center gap-2">' +
    '<button class="chat-sessions text-stone-400 hover:text-stone-700 dark:hover:text-stone-200" title="this workspace\'s sessions">sessions ▾</button>' +
    '<button class="chat-new text-stone-400 hover:text-stone-700 dark:hover:text-stone-200" title="start a new session (clears context)">＋ new</button>' +
    '<button class="chat-x text-stone-400 hover:text-stone-700 dark:hover:text-stone-200 text-xl leading-none" title="close">×</button></span></div>' +
    '<div class="chat-meta flex items-center justify-between px-4 py-1.5 border-b border-stone-200 dark:border-stone-800 font-mono text-[11px] text-stone-400"></div>' +
    '<div class="chat-picker hidden flex-col gap-0.5 max-h-56 overflow-y-auto px-2 py-2 border-b border-stone-200 dark:border-stone-800 bg-stone-50 dark:bg-stone-950 text-sm"></div>' +
    '<div class="chat-log flex-1 overflow-y-auto p-4 flex flex-col gap-3"></div>' +
    '<form class="chat-form border-t border-stone-200 dark:border-stone-800 p-2.5 flex flex-col gap-2">' +
    '<select class="chat-model self-start max-w-full rounded-lg border border-stone-200 dark:border-stone-700 ' +
    'bg-stone-50 dark:bg-stone-950 text-stone-600 dark:text-stone-300 font-mono text-[11px] px-2 py-1 ' +
    'focus:outline-none focus:border-amber-500"><option value="">default model</option></select>' +
    '<textarea rows="2" class="w-full resize-none rounded-lg border border-stone-200 dark:border-stone-700 ' +
    'bg-stone-50 dark:bg-stone-950 text-stone-800 dark:text-stone-100 text-sm p-2.5 focus:outline-none focus:border-amber-500" ' +
    'placeholder="Ask about the codebase… (Enter to send)"></textarea></form></aside>';
  document.body.appendChild(root);

  const fab = root.querySelector(".chat-fab");
  const panel = root.querySelector(".chat-panel");
  const meta = root.querySelector(".chat-meta");
  const picker = root.querySelector(".chat-picker");
  const log = root.querySelector(".chat-log");
  const form = root.querySelector(".chat-form");
  const input = form.querySelector("textarea");
  const modelSelect = root.querySelector(".chat-model");

  let conn = null;        // { client, sessionId, replica, abort } once attached
  let starting = null;    // in-flight ensureSession(), so concurrent sends don't double-create
  let outbox = [];        // user texts sent this session, shown optimistically until committed
  let banner = "";        // status/error line; empty means show the session summary
  let bannerCls = "";
  let workspaceId = null; // docs-html workspace id, resolved once via workspace.describe
  let chosenModel = savedModel(); // "" means the daemon default
  let pinned = true;      // stick to the bottom only while the reader is already there
  let selfScroll = false; // guards the scroll event our own stickToBottom triggers

  // Autoscroll follows the stream only when pinned; scrolling up to read history clears the pin, and
  // scrolling back to the bottom restores it. (Mirrors yuke-client's Transcript.svelte.)
  function atBottom() {
    return log.scrollHeight - log.scrollTop - log.clientHeight < 48;
  }

  function stickToBottom() {
    const max = log.scrollHeight - log.clientHeight;
    if (log.scrollTop >= max - 1) return;  // already there — no scroll event would fire
    selfScroll = true;
    log.scrollTop = max;
  }

  log.addEventListener("scroll", function () {
    if (selfScroll) { selfScroll = false; return; }  // our own scroll — leave `pinned` alone
    pinned = atBottom();
  });

  function setBanner(text, cls) {
    banner = text;
    bannerCls = cls || "text-stone-400";
    updateMeta();
  }

  function updateMeta() {
    if (banner) {
      meta.innerHTML = '<span class="' + bannerCls + '">' + escapeHtml(banner) + "</span>";
      return;
    }
    const n = conn ? conn.replica.messages.length : 0;
    const id = state.sessionId ? state.sessionId.slice(0, 8) : "—";
    meta.innerHTML = "<span>session " + id + " · " + n + " message" + (n === 1 ? "" : "s") + "</span>";
  }

  // The whole log is rebuilt from replica state on every change. Guide chats are short, so a full
  // rebuild is simpler than diffing and never drifts from the daemon's committed truth.
  function render() {
    const views = [];
    let committedUsers = 0;
    if (conn) {
      conn.replica.messages.forEach(function (m) {
        const v = messageView(m);
        if (!v) return;
        views.push(v);
        if (v.role === "user") committedUsers++;
      });
      const active = activeView(conn.replica);
      if (active) views.push(active);
    }

    // Show optimistic bubbles for our sends not yet committed. `baseUsers` is the committed user
    // count at attach time, so we count only user messages this browser added, not the whole history.
    const base = conn ? conn.baseUsers : 0;
    const delivered = Math.max(0, committedUsers - base);
    outbox.slice(delivered).forEach(function (t) { views.push({ role: "user", text: t, pending: true }); });

    // Rebuilding innerHTML resets scrollTop to 0; keep the reader's place when they've scrolled up.
    const prevTop = log.scrollTop;
    log.innerHTML = views.length
      ? views.map(bubbleHtml).join("")
      : '<div class="text-sm text-stone-400 leading-relaxed">Ask about the codebase. The guide reads the ' +
        "live tree and cites <code class=\"font-mono\">path:line</code>.</div>";
    if (pinned) stickToBottom();
    else log.scrollTop = prevTop;
    updateMeta();
  }

  function connError(e) {
    const msg = (e && e.message) || String(e);
    return "can't reach yuked on " + DAEMON_HOST + ":" + DAEMON_PORT +
      " — is it running and is this origin allowed? (" + msg + ")";
  }

  // Fold broadcasts into the replica until the connection closes. A gap forces a resync.
  async function pump(c, stream) {
    try {
      for await (const event of stream) {
        const result = c.replica.applyBroadcast(event);
        if (result.kind === "gap") {
          c.replica.installSnapshot(await c.client.request("session.resync", { session_id: c.sessionId }));
        }
        render();
      }
    } catch (e) {
      if (!c.abort.signal.aborted) {
        clientPromise = null;
        if (conn === c) conn = null;
        setBanner("disconnected — reconnecting on your next message", "text-rose-600 dark:text-rose-400");
      }
    }
  }

  async function ensureSession() {
    if (conn) return conn;
    if (starting) return starting;

    starting = (async function () {
      setBanner("connecting to yuked…", "text-stone-400");
      const client = await daemonClient();
      const yuke = await sdk();

      let sessionId = state.sessionId;
      if (!sessionId) {
        const guide = await guideInfo();
        const params = {
          workspace_path: guide.workspace,
          system_prompt: guide.system_prompt,
          permission: "yolo",
        };
        if (chosenModel) params.model = chosenModel;
        const created = await client.request("session.create", params);
        sessionId = created.session.id;
        state.sessionId = sessionId;
        saveChat(state);
      }

      const replica = new yuke.SessionReplica(sessionId);
      const abort = new AbortController();
      const stream = client.broadcasts({ signal: abort.signal });
      try {
        await client.request("subscription.set", { sessions: [sessionId] });
        replica.installSnapshot(await client.request("session.resync", { session_id: sessionId }));
      } catch (e) {
        // A stored id the daemon no longer knows (removed session): drop it and start clean next send.
        abort.abort();
        if (state.sessionId === sessionId) { state.sessionId = null; saveChat(state); }
        throw e;
      }

      const baseUsers = replica.messages.filter(function (m) { return m.type === "user"; }).length;
      conn = { client: client, sessionId: sessionId, replica: replica, abort: abort, baseUsers: baseUsers };
      setBanner("", "");
      render();
      pump(conn, stream);

      return conn;
    })();

    try {
      return await starting;
    } finally {
      starting = null;
    }
  }

  async function send(text) {
    outbox.push(text);
    pinned = true;  // following your own question back to the answer
    render();
    try {
      const c = await ensureSession();
      await c.client.request("session.send_input", {
        session_id: c.sessionId,
        input: { type: "content", content: [{ type: "text", text: text }] },
      });
    } catch (e) {
      setBanner(connError(e), "text-rose-600 dark:text-rose-400");
    }
  }

  // ---- workspace-scoped session picker ----

  async function ensureWorkspaceId(client) {
    if (workspaceId) return workspaceId;
    const guide = await guideInfo();
    const described = await client.request("workspace.describe", { path: guide.workspace });
    workspaceId = described.workspace.id;

    return workspaceId;
  }

  async function listSessions() {
    const client = await daemonClient();
    const wsId = await ensureWorkspaceId(client);
    const res = await client.request("session.list", { scope: { type: "workspace", workspace_id: wsId } });

    return res.items;
  }

  function pickerRow(item) {
    const s = item.session;
    const act = item.activity && item.activity.state ? item.activity.state.type : "idle";
    const current = s.id === state.sessionId ? " bg-amber-500/10" : "";
    const label = formatWhen(s.updated_at_ms || s.created_at_ms) || s.id.slice(0, 8);
    const meta = s.message_count + " msg" + (s.message_count === 1 ? "" : "s") +
      (act !== "idle" ? " · " + act : "") + " · " + s.id.slice(0, 8);

    return '<button class="picker-row w-full text-left px-3 py-2 rounded-lg hover:bg-stone-100 ' +
      'dark:hover:bg-stone-800 flex items-center justify-between gap-3' + current + '" data-id="' + s.id + '">' +
      '<span class="truncate text-stone-800 dark:text-stone-100">' + escapeHtml(label) + "</span>" +
      '<span class="font-mono text-[10px] text-stone-400 whitespace-nowrap">' + escapeHtml(meta) + "</span></button>";
  }

  function closePicker() {
    picker.classList.add("hidden");
    picker.classList.remove("flex");
  }

  async function openPicker() {
    picker.classList.remove("hidden");
    picker.classList.add("flex");
    picker.innerHTML = '<div class="px-2 py-1 text-[11px] text-stone-400">loading sessions…</div>';
    try {
      const items = await listSessions();
      if (!items.length) {
        picker.innerHTML = '<div class="px-2 py-1 text-[11px] text-stone-400">no sessions in this workspace yet</div>';
        return;
      }
      picker.innerHTML = items.map(pickerRow).join("");
      picker.querySelectorAll(".picker-row").forEach(function (row) {
        row.addEventListener("click", function () { switchTo(row.dataset.id); });
      });
    } catch (e) {
      picker.innerHTML = '<div class="px-2 py-1 text-[11px] text-rose-600 dark:text-rose-400">' + escapeHtml(connError(e)) + "</div>";
    }
  }

  async function switchTo(id) {
    closePicker();
    if (id === state.sessionId && conn) return;

    if (conn) { conn.abort.abort(); conn = null; }
    outbox = [];
    pinned = true;
    state.sessionId = id;
    saveChat(state);
    setBanner("", "");
    render();
    try {
      await ensureSession();
    } catch (e) {
      setBanner(connError(e), "text-rose-600 dark:text-rose-400");
    }
  }

  // ---- model picker ----

  async function populateModels() {
    try {
      const models = await loadModels();
      if (!models.length) return;  // no credential / empty catalog — keep the "default model" option
      modelSelect.innerHTML = '<option value="">default model</option>' + modelOptionsHtml(models, chosenModel);
    } catch (e) {
      // Catalog unreachable is not fatal — the daemon default still runs; leave the lone option.
    }
  }

  modelSelect.addEventListener("change", async function () {
    chosenModel = modelSelect.value || "";
    rememberModel(chosenModel);
    // Apply to the live session immediately; it takes effect on the next run. A fresh session picks
    // it up at create time instead.
    if (conn && chosenModel) {
      try {
        await conn.client.request("session.patch", { session_id: conn.sessionId, patch: { model: chosenModel } });
      } catch (e) {
        setBanner("couldn't switch model: " + ((e && e.message) || e), "text-rose-600 dark:text-rose-400");
      }
    }
  });

  const PANEL_W = 420;

  function applyPush() {
    // Reserve space on wide screens so nothing is hidden; overlay on narrow ones (no room).
    const wide = window.innerWidth >= 1100;
    document.body.style.transition = "padding-right 200ms ease";
    document.body.style.paddingRight = state.open && wide ? PANEL_W + "px" : "";
  }

  function setOpen(open) {
    state.open = open;
    panel.classList.toggle("translate-x-full", !open);
    panel.classList.toggle("translate-x-0", open);
    fab.classList.toggle("hidden", open);
    applyPush();
    saveChat(state);
    if (open) {
      input.focus({ preventScroll: true });
      populateModels();
      // Restore an existing session's transcript; a fresh chat waits for the first send to create one.
      if (state.sessionId && !conn) ensureSession().catch(function (e) { setBanner(connError(e), "text-rose-600 dark:text-rose-400"); });
    }
  }

  window.addEventListener("resize", applyPush);

  fab.addEventListener("click", function () { setOpen(true); });
  root.querySelector(".chat-x").addEventListener("click", function () { closePicker(); setOpen(false); });
  root.querySelector(".chat-sessions").addEventListener("click", function () {
    if (picker.classList.contains("hidden")) openPicker();
    else closePicker();
  });
  root.querySelector(".chat-new").addEventListener("click", function () {
    closePicker();
    if (conn) { conn.abort.abort(); conn = null; }
    outbox = [];
    pinned = true;
    state.sessionId = null;
    saveChat(state);
    setBanner("", "");
    render();
    input.focus({ preventScroll: true });
  });

  form.addEventListener("submit", function (e) {
    e.preventDefault();
    const text = input.value.trim();
    if (!text) return;
    input.value = "";
    send(text);
  });
  input.addEventListener("keydown", function (e) {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); form.requestSubmit(); }
  });

  render();

  if (state.open) setOpen(true);
}

// ---------- boot ----------

document.addEventListener("DOMContentLoaded", function () {
  populateNav();
  populatePagesList();
  document.querySelectorAll(".src[data-file]").forEach(load);
  loadStats();
  liveReload();
  buildChat();

  const here = location.pathname.split("/").pop() || "index.html";
  // The dynamic nav highlights its own active link; this loop is a fallback for any static <a>s.
  document.querySelectorAll("nav.top a").forEach(function (link) {
    if (link.getAttribute("href") === here) {
      link.classList.add("bg-amber-500/15", "text-amber-700", "dark:text-amber-400");
    }
  });
});
