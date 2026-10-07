# engine

Conversation execution for the yuke coding agent. A `Conversation` decides each step without I/O. A `Driver` carries
out the steps over a caller's `ai` transport.

## Examples

Set `MINIMAX_API_KEY`. These examples send live requests. API charges can apply.

| Example | Command |
| --- | --- |
| [Chat](examples/engine_chat.rs) | `mise exec -- cargo run -p engine --example engine_chat` |
| [Tool calls](examples/engine_tools.rs) | `mise exec -- cargo run -p engine --example engine_tools` |
| [Approval](examples/approve.rs) | `mise exec -- cargo run -p engine --example approve` |
