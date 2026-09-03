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
zig build test          # build and run all tests
zig build test-js       # run the QuickJS host tests
zig build               # compile yuke
zig build gen-schema    # regenerate schema/proto.json from the Zig types
zig build sqlgen -- --migrations <dir> --queries <dir> --queries-out <file>
```

## License

MIT
