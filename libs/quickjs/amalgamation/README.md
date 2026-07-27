# QuickJS-NG amalgamation (static link, every platform)

Unlike `libs/sqlite`, there is **no system library fallback**. QuickJS is not
shipped by macOS, is packaged inconsistently and without headers on Linux, and
upstream publishes no prebuilt libraries — only `qjs`/`qjsc` executables. Every
target therefore links a static archive built here from the official
[amalgamated build](https://quickjs-ng.github.io/quickjs/building#amalgamated-builds).

The foreign import ladder lives in `libs/quickjs/c.odin` and expects:

```
bin/linux_amd64/quickjs.a
bin/linux_arm64/quickjs.a
bin/darwin_amd64/quickjs.a
bin/darwin_arm64/quickjs.a
bin/windows_amd64/quickjs.lib
```

## Fetch + build

From the repo root (requires network once, then a C toolchain):

```bash
# Downloads the pinned amalgamation into this directory, then builds the
# archive for the host target.
make quickjs-static
```

On Windows with MSVC (x64 Native Tools shell):

```bat
make quickjs-static
rem or: libs\quickjs\build_static.bat
```

`build_static.bat` needs the MSVC environment; outside an x64 Native Tools shell,
`call "…\VC\Auxiliary\Build\vcvars64.bat"` first. MSVC emits four benign C4098
warnings (upstream returns a value from `void` in the `JS_FreeCString*` wrappers);
they are not errors.

Artifacts land in `libs/quickjs/bin/<os>_<arch>/` and are gitignored. Each host
builds its own; cross-compiling the C is out of scope for these scripts.

Windows is verified, not assumed: `bin/windows_amd64/quickjs.lib` built with
MSVC 2022 and the full test suite run under a native `odin.exe` both pass. That
matters because `Value` is returned **by value** from much of the API, and Win64
returns a 16-byte struct through a hidden pointer while SysV returns it in
registers — `odin check -target:windows_amd64` does not link and so cannot
exercise it. Re-run the tests on Windows after any version bump.

## Build flags that matter

- **`-D_GNU_SOURCE` (glibc)** — required for `tm_gmtoff` and `alloca`. The
  amalgamation only defines it for itself under `QJS_BUILD_LIBC`; without either,
  the build fails with an implicit-declaration error on `alloca`.
- **`QJS_BUILD_LIBC` is deliberately NOT set.** `quickjs-libc` would give scripts
  their own filesystem, process, and network access, bypassing the daemon's IO
  primitives and its permission gate.
- **64-bit only.** With `JS_NAN_BOXING` (the default on 32-bit) `JSValue` is 8
  bytes instead of 16, which silently changes the ABI of nearly every call.
  `c.odin` asserts `size_of(Value) == 16` so a mismatched archive fails to
  compile rather than corrupting memory.

## Pin

The Makefile pins a QuickJS-NG release tag and the SHA256 of
`quickjs-amalgam.zip`. Bump both together when upgrading, and re-run the tests:
the binding is hand-written against the C API, so a version bump is a
compatibility question, not a formality.

## Vendoring

`build_static.sh` skips the download when `quickjs-amalgam.c` is already present,
so committing it here later is a drop-in with no script change. That trades
roughly 3 MB of tree for hermetic, offline builds on every platform — worth
considering given that, unlike SQLite, *no* platform can build without this file.
