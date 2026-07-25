# yuke-odin

Odin implementation of the yuke wire protocol (and, later, client/daemon).

## Toolchain

- **Odin `dev-2026-07a`** — pinned by [mise](https://mise.jdx.dev) in `.mise.toml`.
- **[odinfmt](https://github.com/DanielGavin/ols)** — config in `odinfmt.json`, run via `make fmt`.

```sh
mise install          # once, to fetch the pinned Odin
make test             # build + run wire tests
make fmt              # format sources
```

## Conventions

Doc-comment markers, one per line above the declaration's comment. The compiler
enforces none of them; the `enforce_*` procs do.

| Marker | Meaning |
|---|---|
| `@private` | Package-internal field. |
| `@bounded N` | Max byte/element length, via `enforce_bounded`. `N` is a literal or a `LIMITS` field. |
| `@fixed N` | Exact byte length, via `enforce_fixed*` or `enforce_id`. |
| `@unbounded` | Deliberately no length limit. |
