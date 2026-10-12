# agent

Durable sessions for the yuke coding agent. A `Session` runs each turn of `yuke-engine` on its context, and saves each
commit of the turn in a `Store` before the turn goes on.

## Store

Each `Store` method is one atomic durable step: create a session, fork it, set its settings, accept an input, open it,
save one commit of the engine, load the pending inputs, load the events, put and read a blob, and delete a session.
Each commit and each settings change is also a numbered event, and the first event of a session holds its settings.
`Store::events(id, after)` gives the events after an `EventNumber`, so a reader sees each of them once and in order. An
accepted input is no event: it waits in the queue of `Store::pending`, and the commit that consumes it holds its blocks
and names its id. One writer at a time owns a session. A second writer gets `StoreError::Owned` until the `Lease` of the first writer drops. `MemoryStore`
keeps its sessions in memory.

A blob belongs to one session, and `blob_of` gives its reference: the SHA-256 and the length of its bytes. A session
turn reads the blobs of its media from the store, so the driver needs no blob store of the caller.

## Session

- `Session::open` ends a turn that was open when its process stopped. Each call without a result gets an error result,
  and the turn ends as failed. The session sends no request again.
- `Session::fork` copies a session up to the end of a completed turn into a new session, and the returned `Session`
  owns the new session. The copy has the events up to that end, the settings at that point, the blobs of the source,
  no pending input, and no open turn. A fork names the end by its event number, or takes the newest completed turn. A
  number that does not end a completed turn gets `StoreError::NotACompletedTurn`.
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
