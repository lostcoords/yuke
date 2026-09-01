# Blob lifetime and garbage collection

Status: proposal.
Source of truth: future blob routes and the durable message/input projections.
Last verified: 2026-08-31.

## Decision

A blob stays available while any retained record references it. Session deletion is
not the only condition that can release a blob. Transcript truncation, rewind,
compaction, queue cancellation, and fork deletion can also remove references.

If a retained message references a deleted blob, the chat can show the message
metadata but cannot display the image or send it to the model again.

## Durable references

The garbage collector must account for every record that can name a blob:

- committed messages;
- queued inputs;
- forked sessions;
- replayable events and recovery records.

Yuke currently stores committed message bodies in `events.payload` and queued
input bodies in `pending_inputs.payload`. Both paths must remain reachable until
their records no longer exist or no longer form part of the retained history.

A shared content-addressed blob stays when another session still references the
same hash. Deleting one session must not delete a shared blob.

## Blob lifecycle

```text
uploaded and unreferenced
        |
        | 24-hour upload grace period
        v
       deleted

referenced by a durable record
        |
        | last reference is removed
        v
orphaned and unreferenced
        |
        | 24-hour orphan grace period
        v
       deleted
```

The server computes the hash during `PUT /blob`. The message request then names
that hash. The message commit must validate that the blob exists and must create
the durable reference in the same database transaction as the message.

An upload that never receives a message reference is an orphan. The upload grace
period protects against a client disconnect or a daemon restart between the two
requests.

When the last durable reference disappears, the server records an orphan time.
The second grace period protects retries and delayed cleanup after session or
transcript changes.

## Initial timing

- Run garbage collection once per hour.
- Delete an upload that has never received a reference after 24 hours.
- Delete a previously referenced blob 24 hours after its last reference ends.
- Never delete a blob only because it is old.
- Use a longer period, such as seven days, if clients can upload days before
  they send a saved draft.

The collector should process a bounded number of blobs or bytes per run. Session
deletion should release references and let the next collector run remove files;
it should not perform file deletion inside the session database transaction.

## Reference tracking

The preferred design is a normalized `blob_refs` table. The daemon updates it in
the same transaction that commits a message or queues an input. Garbage
collection can then identify an orphan with a `NOT EXISTS` reference query.

This is safer than scanning JSON payloads during every collection pass. It also
makes shared blobs, forks, truncation, and session deletion explicit.

The collector must recheck the reference immediately before deleting a file. A
new message can reference a blob after an earlier scan marks it as a candidate.

Git follows the same general rule for unreachable content: it keeps unreachable
objects for a grace period instead of deleting them immediately. Its default
grace period is two weeks. Yuke can use a shorter period because the upload and
message requests should normally occur close together.

See the [Git garbage-collection documentation](https://git-scm.com/docs/git-gc.html).

This note records the design direction only. It does not add the `/blob`
endpoint or the garbage collector.
