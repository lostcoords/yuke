/*
package offload runs blocking work on a worker thread and delivers the result back on the
event loop that submitted it.

`core:nbio` has no operation for `fsync`, `rename`, `unlink`, directory listing, or path
resolution, and its `stat` takes an open handle rather than a path. Those calls are
therefore synchronous, and making one from a reactor callback stalls every other
connection sharing that loop. This package is the way off the loop: a task's `work` runs
on a worker thread, and its `done` runs on the loop thread once the work has finished.

The return path is nbio's own cross-thread mechanism. A worker submits a zero-duration
timeout against the submitting loop, which enqueues onto that loop's queue and wakes it;
the completion then fires on the loop thread. A zero timeout is the only operation that
carries no I/O, so it is how a worker hands back a pure continuation.

**A submitted task cannot be cancelled.** A worker already inside a syscall cannot be
interrupted, so `done` always runs, even when whatever asked for the work is gone. Two
rules follow, and both are load-bearing:

- A task owns every input its `work` reads. Nothing borrowed from a request arena, a
  frame buffer, or a connection may be reachable from a worker thread.
- A task never holds a pointer to something whose lifetime it does not control. To decide
  whether the requester is still there, carry a key that can be re-resolved on the loop
  thread, and tolerate a miss.

Threading:

- `work` runs on a worker thread and may touch only the state handed to it. It must not
  log, must not allocate from a loop-thread allocator, and must not use
  `context.temp_allocator`, which is per-OS-thread and shared with anything else that
  worker runs.
- `done` runs on the loop thread and owns the state again, including freeing it.

Shutdown drains, never terminates. `pool_drain` finishes queued tasks, joins the workers,
then ticks the loop until every `done` has run; only then may `pool_destroy` release the
pool. Skipping the tick leaks every task whose work finished while its completion was
still queued. `core:thread`'s `pool_shutdown` and `pool_stop_all_tasks` kill threads
outright and are never correct here: a worker terminated mid-`rename` leaves the
filesystem half-published.
*/
package offload
