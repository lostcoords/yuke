# agent

Durable sessions for the yuke coding agent. A `Session` runs each turn of `yuke-engine` on its context, and saves each
commit of the turn in a `Store` before the turn goes on.

## Store

Each `Store` method is one atomic durable step. The methods create or fork a session, set its settings, accept or remove
an input, open a session, save one commit of the engine, load the pending inputs, load the events with the pending
inputs, put or read a blob, and delete a session. Each commit and each settings change is also a numbered event, and the first event of a
session holds its settings. `Store::load(id, after)` gives the events after a `yuke_protocol::EventNumber` and the
pending inputs from one moment, so a reader sees each event once and in order, and misses no input. An
accepted input is no event. It waits in the queue of `Store::pending`. The commit that consumes it starts with its model
blocks. The commit also keeps a record of the input: its id, its source, and its block count. The record keeps the
content that the user saw only when that content differs. A commit of an input that is not pending saves nothing. One writer at a time owns a session. A second writer gets `StoreError::Owned` until the `Lease` of the first writer drops. `MemoryStore`
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
- An input from `Store::accept_input` is pending in the store until a commit consumes it. An open starts no turn.
- A turn reads the pending inputs from the store at its start and after each round. After a cancelled or failed turn,
  the next turn adds a notification from `host:session` after its inputs.
- After a failed commit, or when the caller drops a turn, the session is stale. `Session::recover` opens it again
  from the store before the next turn.

## Session updates

`SessionTurn::observer` accepts a `SessionObserver`. It receives typed `SessionUpdate` values, with no JSON round trip.
The callback receives owned updates and must return without a wait. The caller owns any delivery queue.

Each provider attempt starts a distinct draft. Model updates retain block ids, boundaries, reasoning sections,
argument fragments, and response completion. A response completion does not confirm a save or end the turn.

`Store::commit` returns its assigned event number after the durable write succeeds. The session publishes that saved
commit before it reconciles the draft. `DraftCommitted` carries the event number and the original draft block ids.
The array index is the destination block index within that commit.
The client removes the whole draft, including blocks absent from the array, and uses the saved event as history.
A failed attempt discards its draft. An unconfirmed write or dropped turn also discards its draft. Reload the journal
to resolve a write whose result is uncertain. `TurnUnconfirmed` marks a turn that stops without a confirmed terminal
commit. Discard its provisional tool state and reload the journal. Results in confirmed saved events remain valid.

Tool updates identify the call by its saved event number and block index within that event. The enclosing session id
completes this identity. Provider call ids remain model data and can repeat. Parallel tool results can arrive in a
different order from their saved order. A live result remains provisional until a saved commit confirms it.
`TurnUnconfirmed` invalidates provisional results. The client must then reload the journal.

This observer covers commits and live facts of its turn. It is not a subscription to other store writes.
Reconnect snapshots, settings publication, and client queue policy belong to the server delivery layer.

## Shared store tests

The `testing` feature gives one test function for each store behavior. `store_tests!(make_store)` writes one
`#[tokio::test]` for each, so each store runs the same list:

```rust
async fn make_store(_test: &str) -> std::sync::Arc<MyStore> {
    std::sync::Arc::new(MyStore::new())
}

yuke_agent::store_tests!(make_store);
```
