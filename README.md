# yuke-odin

Odin implementation of the yuke wire protocol and runtime foundations. The strict wire codec,
client replica, HTTP/WebSocket daemon front door, SQLite event store/pump, curl/SSE transport,
and Anthropic provider request builder/decoder/turn driver have landed. The agent round loop,
OpenAI provider implementations, real-model integration, and a `yuked` process entrypoint remain
under construction.

**Client (`yuke`):** TUI + QuickJS (`yuke:term` double-buffer paint). The `yuke:term` draw
contract lives in its host (`src/yuke/host.odin`, `js.odin`).

Provider work: [`docs/llm-transport-design.md`](docs/llm-transport-design.md).

## Toolchain

- **Odin `dev-2026-07a`** — pinned by [mise](https://mise.jdx.dev) in `.mise.toml`.
- **[odinfmt](https://github.com/DanielGavin/ols)** — config in `odinfmt.json`, run via `./build.py fmt`.

```sh
mise install                # once, to fetch the pinned Odin
./build.py setup            # once, to install the pre-commit schema-check hook
./build.py deps             # QuickJS (+ sqlite) static archives
./build.py test             # build + run the aggregate repository suite
./build.py test wire        # one package; ./build.py help lists them all
./build.py yuke             # build client → ./build/yuke
./build.py check-windows    # cross-compile type-check supported Windows package arms
./build.py fmt-check        # report unformatted sources; `fmt` rewrites them
```

Every compile runs `-vet -strict-style -warnings-as-errors`, and tests fail on a
leak or bad free.

## Conventions

Doc-comment markers, one per line above the declaration's comment. The compiler
enforces none of them; the `enforce_*` procs do.

| Marker | Meaning |
|---|---|
| `@private` | Package-internal field. |
| `@bounded N` | Max byte/element length, via `enforce_bounded`. `N` is a literal or a `LIMITS` field. |
| `@fixed N` | Exact byte length, via `enforce_fixed*` or `enforce_id`. |
| `@unbounded` | Deliberately no length limit. |
