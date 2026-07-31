# SQLite amalgamation (Windows static link)

Unix builds link the system `libsqlite3`. Windows builds link a **static**
`libs/bindings/sqlite/bin/sqlite3.lib` produced from the official amalgamation.
The foreign import lives in `libs/bindings/sqlite/c.odin` as `@(private)` (`bin/sqlite3.lib`).

## Fetch + build

From the repo root (requires network once, then a C toolchain):

```bash
# Downloads a pinned amalgamation into this directory, then builds the static lib.
make deps
```

On Windows with MSVC (x64 Native Tools shell):

```bat
make deps
rem or: libs\bindings\sqlite\build_static.bat
```

Artifacts land in `libs/bindings/sqlite/bin/` and are gitignored.

## Pin

The Makefile pins a SQLite version and SHA256. Bump both when upgrading.

Do **not** commit `sqlite3.c` / `sqlite3.h` unless we later decide to vendor
them offline; the fetch step keeps the git tree small on Unix-first development.
