# engine

Conversation execution for the yuke coding agent. A `Driver` runs each turn on the caller's history. It sends requests
over the caller's `ai` transport.

## Examples

Set `MINIMAX_API_KEY`. These examples send live requests. API charges can apply.

| Example | Command |
| --- | --- |
| [Chat](examples/engine_chat.rs) | `mise exec -- cargo run -p yuke-engine --example engine_chat` |
| [Tool calls](examples/engine_tools.rs) | `mise exec -- cargo run -p yuke-engine --example engine_tools` |
| [Approval](examples/approve.rs) | `mise exec -- cargo run -p yuke-engine --example approve` |
