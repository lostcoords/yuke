# Package tools

Package and release tasks need Python 3.9 or later. Normal Cargo development and the installed program do not.
Linux builds also need Docker or Podman for the pinned cross images.
Those images use x86-64 host tools, so Apple silicon needs emulation.

## Build

```sh
mise run package
mise run package --target x86_64-unknown-linux-musl
```

Archives go to `target/packages/` and contain `bin/yuke` and `lib/yuke`.
Use `--target` to select another platform.

## Test

```sh
mise run package:test-builder
mise run release:test
mise run package:test target/packages/yuke-aarch64-macos.tar.gz
```

Run package tests on the matching OS and architecture.

## Install

```sh
mise exec -- bash tools/install.sh target/packages/yuke-aarch64-macos.tar.gz
```

The installer writes `~/.local/bin/yuke` and `~/.local/lib/yuke` and preserves user configuration.

## Releases

A `vVERSION` tag runs CI and publishes all four archives through a draft release.
The tag must match `crates/yuke/Cargo.toml` without `-dev`. A hyphen suffix creates a prerelease.
Successful push CI on `main` triggers the rolling nightly. Manual runs also require successful CI.
Stale runs skip publication. Nightly needs mutable releases.
Published versioned releases stay unchanged. An upload or publish failure can hide nightly until retry.
Retry all jobs to rebuild expired artifacts and complete the draft.

## Benchmarks

`bench-idle.py` measures agents at rest: startup time, idle memory, idle CPU, and binary size.
It needs tmux. It starts each agent in an empty directory and prints a Markdown table.

```sh
python3 tools/bench-idle.py yuke=target/release/yuke "Claude Code=claude" Codex=codex
```

The [benchmarks page](../docs/guide/benchmarks.md) publishes the results and the method.
