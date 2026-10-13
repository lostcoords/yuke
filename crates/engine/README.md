# engine

Assistant turns for the yuke coding agent. A `Driver` runs each turn on the caller's context. It sends requests
over the caller's `ai` transport.

By default, a `Driver` uses `retry::Policy::default()` and `ResponseLimits::default()` of `yuke-ai`. The
[`ai` README](../ai/README.md#defaults) gives their values. Set them with `Driver::retry_policy` and
`Driver::response_limits`.

## Examples

Set `MINIMAX_API_KEY`. These examples send live requests. API charges can apply.

| Example | Command |
| --- | --- |
| [Chat](examples/engine_chat.rs) | `mise exec -- cargo run -p yuke-engine --example engine_chat` |
| [Tool calls](examples/engine_tools.rs) | `mise exec -- cargo run -p yuke-engine --example engine_tools` |
| [Approval](examples/approve.rs) | `mise exec -- cargo run -p yuke-engine --example approve` |
