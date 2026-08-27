# yuke

Unleash you harness.

## Development

- Zig **0.16.0**

```sh
mise install
git config core.hooksPath .githooks
```

## Commands

```sh
zig build test          # build and run the wire tests
zig build               # install yuke (TUI by default; --daemon starts the server)
zig build gen-schema    # regenerate schema/wire.json from the Zig types
zig build sqlgen -- --migrations <dir> --queries <dir> --queries-out <file>
```

## License

Apache License 2.0
