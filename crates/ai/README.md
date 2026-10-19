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

All protocols work without default features. Supply a custom [`Transport`](src/transport.rs). The OAuth flows of
[`oauth`](src/oauth.rs) need an [`Exchange`](src/transport.rs).

## Defaults

The caller can change each default: [`HttpOptions::new`](src/http.rs), [`ResponseLimits::default`](src/response.rs),
and [`retry::Policy::default`](src/retry.rs).

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
