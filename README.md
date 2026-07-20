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
