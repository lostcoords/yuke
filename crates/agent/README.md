# agent

Durable sessions for the yuke coding agent. A `Session` runs each turn of `yuke-engine` on its history, and saves each
commit of the turn in a `Store` before the turn goes on.

## Store

Each `Store` method is one atomic durable step: create a session, set its settings, accept an input, open it, save
one commit of the engine, and load the pending inputs. One writer at a time owns a session. A second writer gets
`StoreError::Owned` until the `Lease` of the first writer drops. `MemoryStore` keeps its sessions in memory.

## Session

- `Session::open` ends a turn that was open when its process stopped. Each call without a result gets an error result,
  and the turn ends as failed. The session sends no request again.
- An input from `Session::input` is pending in the store until a commit consumes it. An open starts no turn.
- After a failed commit, or when the caller drops a turn, the next turn opens the session again from the store.

## Shared store tests

The `testing` feature gives one test function for each store behavior. `store_tests!(make_store)` writes one
`#[tokio::test]` for each, so each store runs the same list:

```rust
async fn make_store(_test: &str) -> std::sync::Arc<MyStore> {
    std::sync::Arc::new(MyStore::new())
}

yuke_agent::store_tests!(make_store);
```
