# yuke

Unleash you harness.

## Development

- Zig **0.16.0**

```sh
mise install
git config core.hooksPath .githooks
mise run install
```

`mise run install` builds an optimized Yuke, installs it at `~/.local/bin/yuke`, and refreshes the plugin types. The local build version includes the source revision and UTC build time, for example `0.0.1-dev+abcdef123456.b20261010104300`. In a jj checkout, the revision identifies the working-copy snapshot, including local edits. Run `yuke --version` to check the installed binary. The `initialize` RPC reports the version embedded in the running process, which does not change when you install another binary.

`python3 tools/test-install.py` checks the build stamp and install paths in a temporary home without compiling.

## Commands

```sh
zig build test          # build and run all tests
zig build test-js       # run the process and QuickJS host tests
zig build               # compile yuke
zig build gen-schema    # regenerate schema/proto.json from the Zig types
mise run types          # regenerate the plugin declarations in src/js/app/generated
zig build sqlgen -- --migrations <dir> --queries <dir> --queries-out <file>
```

## JSONL RPC

Run `yuke --rpc` for a local JSONL client on stdin and stdout.
`initialize` is optional version discovery. It accepts empty parameters and reports the server protocol version.
A client can call it before other methods to check compatibility. The server has no version handshake or client-version field.

## Customize yuke

A profile (`~/.config/yuke/index.js`) changes yuke: commands, keys, tools, hooks, plugins, and config. The [Markdown guides](docs/index.md) explain concepts and recipes. The generated `yuke.d.ts` is the exact public API reference. [`docs/examples/`](docs/examples/) contains checked patterns. Source inspection is only for undocumented behavior or implementation details.

The installer ships the guides in `~/.local/lib/yuke/docs`. It also links the `yuke` agent skill into `~/.agents/skills/yuke`, so a coding agent can change a profile without the yuke source.

## License

MIT
