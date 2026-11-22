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
mise run package:test target/packages/yuke-aarch64-macos.tar.gz
```

Run package tests on the matching OS and architecture.

## Install

```sh
mise exec -- bash tools/install.sh target/packages/yuke-aarch64-macos.tar.gz
```

The installer writes `~/.local/bin/yuke` and `~/.local/lib/yuke` and preserves user configuration.
With no archive, it downloads one: `YUKE_CHANNEL` selects `stable` or `nightly`, and `YUKE_VERSION` selects a tag.
It checks the download against the `SHA256SUMS` file of the release. `yuke update` downloads and runs
`https://yuke.sh/install.sh`.

## Releases

A `vVERSION` tag runs CI, and `gh release create` publishes the four tested archives and their `SHA256SUMS`.
The tag must match the `version` of `[workspace.package]` in `Cargo.toml`, and the version must not hold `-dev`.
A hyphen suffix creates a prerelease.

To release:

1. Set the version in `Cargo.toml`, and run `mise exec -- cargo update --workspace`.
2. Rename the section `## Unreleased` of `CHANGELOG.md` to `## VERSION`. The release job publishes it as the notes, and
   fails without it.
3. Commit, tag `vVERSION`, and push the tag.
4. Set the next version with `-dev`, for example `0.2.0-dev`, so that a nightly sorts after the release.

A push to `main` builds and tests the nightly archives in CI, and a successful CI publishes them as the rolling
nightly. A pull request runs only the checks and the tests. The nightly job deletes the release and the tag `nightly`,
and creates them again on the new commit, so the nightly is absent for a few seconds.
If an upload fails, `gh` leaves a draft release. Delete the draft, then run the job again.
