/*
package offload runs blocking work on a worker thread and delivers the result back on the
event loop that submitted it.

A task's `work` runs on a worker thread, and its `done` runs on the loop thread once the
work has finished.

The return path is nbio's own cross-thread mechanism. Workers publish completed tasks into
an allocation-free intrusive queue. The first result in a batch submits one zero-duration
timeout against the loop, which wakes it and drains the whole batch there. nbio's
cross-thread queue is bounded, so submitting one operation per task could fill it and leave
shutdown joining workers that are waiting for the loop.

A submitted task cannot be cancelled. There is no cancel path: `submitted` only guards
against double submission, and a worker already inside a blocking call cannot be
interrupted. `done` runs even when whatever asked for the work is gone, which shapes the
ownership rules:

- A task owns every input its `work` reads. Nothing borrowed from a request arena, a frame
  buffer, or a connection may be reachable from a worker thread.
- A task never holds a pointer to something whose lifetime it does not control. To decide
  whether the requester is still there, carry a key that can be re-resolved on the loop
  thread, and tolerate a miss.

Threading:

- `pool_init`, `submit`, `pool_drain`, and `pool_destroy` run on the bound loop thread.
  Serializing submission with drain is what makes the pool's accepting state race-free.
- `work` runs on a worker thread and may touch only the state handed to it. It must not log
  and must not allocate: the worker replaces both `context.allocator` and
  `context.temp_allocator` with a panicking allocator, so an accidental allocation fails
  there instead of reaching allocator state owned by another thread.
- `done` runs on the loop thread and owns the state again, including freeing it.
- `done` must not call `pool_drain`: the current task remains outstanding until `done`
  returns, so synchronous drain would wait for its own callback. The attempt returns
  `Completion_In_Progress`; signal the loop's outer owner to drain after the callback
  instead.

Shutdown drains, never terminates. `pool_drain` lets workers finish queued tasks while it
ticks the loop until every `done` has run, and only then joins the workers.
Pumping before join is essential because nbio's cross-thread queue is bounded: a worker
may be waiting for the loop to accept its dispatcher. Only after drain may `pool_destroy`
release the pool. `core:thread`'s `pool_shutdown` and `pool_stop_all_tasks` terminate
threads outright and are never correct here.
*/
package offload
