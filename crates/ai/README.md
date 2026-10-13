# ai

Model calls for the yuke coding agent.

## Supported protocols

- Anthropic Messages
- OpenAI Chat Completions
- OpenAI Responses

## Dependencies

- Rust 1.99 (pinned in [`.mise.toml`](../../.mise.toml))

Catalog generation script:

- Bash
- curl
- jq
- rustfmt

## Cargo features

| Feature | Default | Provides |
| --- | --- | --- |
| `http-tokio` | Enabled | `HttpTransport` and `HttpOptions`. HTTP/1.1 with Tokio, hyper, and rustls. |
| `ts` | Disabled | TypeScript declarations of the serde types through ts-rs. |

All protocols work without default features. Supply a custom [`Transport`](src/transport.rs).

## Defaults

The library uses these default values. The caller can change each field.

| Setting | Default |
| --- | --- |
| `HttpOptions::idle_timeout` | 300 s |
| `ResponseLimits` | 64 MiB response body, 4 MiB event, 1 MiB tool-call arguments, 1,024 blocks, 4 KiB error body |
| `retry::Policy` | 5 attempts, 500 ms base delay, 8 s delay cap, 120 s cap on a server delay |

## Examples

Set `OPENAI_API_KEY`. These examples send live requests. API charges can apply.

| Example | Command |
| --- | --- |
| [One-shot](examples/oneshot.rs) | `mise exec -- cargo run --example oneshot` |
| [Streaming chat](examples/chat.rs) | `mise exec -- cargo run --example chat` |
| [Tool calls](examples/tools.rs) | `mise exec -- cargo run --example tools` |

## Development

Run commands from the repository root.

```sh
mise trust
mise install
mise exec -- cargo fmt --check
mise exec -- cargo clippy --all-targets --all-features -- -D warnings
mise exec -- cargo test --all-features
mise exec -- env RUSTDOCFLAGS=-Dwarnings cargo doc --no-deps --all-features
```

To update the model catalog:

```sh
mise exec -- bash crates/ai/scripts/generate-catalog.sh
```
