package offload

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:nbio"
import "core:sync"
import "core:thread"
import "core:time"

// Per-tick wait while draining. Workers may still be inside blocking calls, so the bound
// returns control regularly to observe their newly published completions.
DRAIN_TICK :: 10 * time.Millisecond

Error :: enum {
    None,
    Invalid_Options,
}

Drain_State_Error :: enum i32 {
    None,
    Completion_In_Progress,
}

Drain_Error :: union #shared_nil {
    Drain_State_Error,
    nbio.General_Error,
}

// Type-erased head of every task, so one worker entry point can drive any `Task(T)`.
// Kept at offset zero: the worker recovers it from the queued pointer.
Task_Base :: struct {
    // @private
    pool:           ^Pool,

    // @private
    // Set between `submit` and `done`; guards against submitting twice.
    submitted:      bool,

    // @private
    // Monomorphic trampolines written by `submit`, which recover the typed state.
    run:            proc(base: ^Task_Base),
    complete:       proc(base: ^Task_Base),

    // @private
    // Intrusive link in the pool's completed queue. Workers publish through this queue
    // without allocating once the task has run.
    completed_next: ^Task_Base,
}

// One in-flight offload. Embedded in its state, so the task itself is never
// allocated per submission. `core:thread` still owns the queue `submit` pushes onto, which
// grows on demand, so submitting is cheap rather than allocation-free.
Task :: struct($T: typeid) {
    using base: Task_Base,

    // @private
    work:       proc(state: ^T),

    // @private
    done:       proc(state: ^T),
}

// Worker pool bound to one event loop. Every task submitted through it completes on that
// loop's thread.
Pool :: struct {
    // @private
    // Borrowed loop every completion is delivered on; the caller owns and runs it.
    loop:                 ^nbio.Event_Loop,

    // @private
    workers:              thread.Pool,

    // @private
    // Serializes the allocation-free intrusive completed queue below. The queue may have
    // many entries, but only one nbio dispatcher is scheduled for it at a time.
    completed_mutex:      sync.Mutex,

    // @private
    completed_head:       ^Task_Base,

    // @private
    completed_tail:       ^Task_Base,

    // @private
    // Protected by `completed_mutex`.
    completion_scheduled: bool,

    // @private
    // Tasks between `submit` and `done`. Read by callers and written on the loop thread,
    // so only ever through atomics.
    outstanding:          int,

    // @private
    // Loop-thread owned. Cleared by `pool_drain`; submitting past that point is a bug.
    accepting:            bool,

    // @private
    // Loop-thread owned. A synchronous drain from inside `done` would wait for that same
    // completion to return, so `pool_drain` rejects any positive depth.
    completion_depth:     int,
}

// Start `worker_count` threads bound to `loop`. Blocking work waits on syscalls rather
// than competing for cores, so a small count is usually the right one. Initialization and
// every later lifecycle operation run on `loop`'s thread.
pool_init :: proc(p: ^Pool, loop: ^nbio.Event_Loop, worker_count: int) -> Error {
    if p == nil || loop == nil || loop != nbio.current_thread_event_loop() || worker_count <= 0 {
        return .Invalid_Options
    }

    p^ = {}
    p.loop = loop

    // `core:thread` allocates its finished-task records on workers and therefore requires
    // an allocator it owns or one that is thread-safe. The process heap has that contract;
    // a caller's potentially loop-confined allocator does not.
    thread.pool_init(&p.workers, runtime.heap_allocator(), worker_count)
    thread.pool_start(&p.workers)
    p.accepting = true

    assert(p.accepting && p.outstanding == 0, "a fresh pool owes no completions")
    assert(p.completed_head == nil && p.completed_tail == nil, "a fresh pool has completed tasks")

    return .None
}

// Hand `state` to a worker: `work` runs there, then `done` runs on the pool's loop.
// `state` must contain a `task: Task(T)` field and stay alive until `done` returns.
// Once submitted the task cannot be cancelled, so `done` will run even if the requester
// is gone by then. Submission must run on the pool's loop thread, serializing it with
// `pool_drain`.
submit :: proc(
    p: ^Pool,
    state: ^$T,
    work: proc(state: ^T),
    done: proc(state: ^T),
) where intrinsics.type_has_field(T, "task"),
    intrinsics.type_field_type(T, "task") ==
    Task(T) {
    assert(p != nil && state != nil, "offload needs a pool and state")
    assert(work != nil && done != nil, "offload needs both a work and a done procedure")
    assert(p.loop == nbio.current_thread_event_loop(), "offload submitted off the pool's loop thread")
    assert(p.accepting, "offload submitted after the pool was drained")

    task := &state.task
    assert(!task.submitted, "offload task submitted while already in flight")
    assert(task.completed_next == nil, "offload task retained a completed-queue link")

    task.pool = p
    task.work = work
    task.done = done
    task.submitted = true

    task.run = proc(base: ^Task_Base) {
        t := (^Task(T))(base)
        state := runtime.container_of(t, T, "task")
        t.work(state)
    }

    task.complete = proc(base: ^Task_Base) {
        t := (^Task(T))(base)
        state := runtime.container_of(t, T, "task")
        t.done(state)
    }

    sync.atomic_add(&p.outstanding, 1)
    thread.pool_add_task(&p.workers, mem.panic_allocator(), _run, &task.base)
}

// Tasks submitted but not yet completed. Informational; the drain loop is the only
// correct way to wait for zero.
pool_outstanding :: proc(p: ^Pool) -> int {
    assert(p != nil, "outstanding needs a pool")
    return sync.atomic_load(&p.outstanding)
}

// Whether `pool_init` has run and `pool_destroy` has not. Lets a caller whose startup
// failed partway tear down unconditionally, since draining a pool that never started
// would trip its own assertions.
pool_is_running :: proc(p: ^Pool) -> bool {
    assert(p != nil, "running check needs a pool")
    return p.loop != nil
}

// Let workers finish their queue while running every completion on the loop, then join
// once no worker can still be publishing. Must run on the pool's loop thread, since that
// is where completions fire.
//
// Pumping before join is load-bearing: a worker returning through nbio may be waiting for
// space in that loop's bounded cross-thread queue.
pool_drain :: proc(p: ^Pool) -> Drain_Error {
    assert(p != nil, "drain needs a pool")
    assert(p.loop == nbio.current_thread_event_loop(), "drain ran off the pool's loop thread")

    if p.completion_depth > 0 {
        return Drain_State_Error.Completion_In_Progress
    }

    p.accepting = false

    drain_err: Drain_Error
    for sync.atomic_load(&p.outstanding) > 0 {
        if err := nbio.tick(DRAIN_TICK); err != nil {
            if drain_err == nil {
                drain_err = err
            }

            // A backend error must not abandon workers or their task state. Cross-thread
            // operations are received before the backend tick, so retry until every
            // completion has been delivered, then report the first error.
            thread.yield()
        }
    }

    // A completion may run just before `core:thread` records its task as done. Nothing can
    // block after publication, so joining here closes that final bookkeeping race.
    thread.pool_join(&p.workers)
    assert(thread.pool_num_waiting(&p.workers) == 0, "joined workers left tasks queued")
    assert(thread.pool_num_outstanding(&p.workers) == 0, "joined workers still owe tasks")

    _reap_finished(p)

    sync.mutex_lock(&p.completed_mutex)
    assert(p.completed_head == nil && p.completed_tail == nil, "drain left completed tasks queued")
    assert(!p.completion_scheduled, "drain left a completion dispatcher scheduled")
    sync.mutex_unlock(&p.completed_mutex)

    return drain_err
}

// Release the pool. `pool_drain` must have run first: destroying with completions
// outstanding would leave a worker's result with nowhere to land.
pool_destroy :: proc(p: ^Pool) {
    assert(p != nil, "destroy needs a pool")
    assert(p.loop == nbio.current_thread_event_loop(), "destroy ran off the pool's loop thread")
    assert(!p.accepting, "pool destroyed before it was drained")
    assert(sync.atomic_load(&p.outstanding) == 0, "pool destroyed with completions outstanding")
    assert(p.completion_depth == 0, "pool destroyed from inside an offload completion")
    assert(p.completed_head == nil && p.completed_tail == nil, "pool destroyed with completed tasks queued")
    assert(!p.completion_scheduled, "pool destroyed with a completion dispatcher scheduled")

    thread.pool_destroy(&p.workers)
    p^ = {}
}

// Worker thread. Runs the blocking half, then hands the completion back to the loop.
//
// `submit` gives `core:thread` a panicking task allocator, and this entry point replaces
// the temp allocator too. An accidental implicit allocation therefore fails here instead
// of reaching allocator state owned by some other thread.
@(private)
_run :: proc(t: thread.Task) {
    base := (^Task_Base)(t.data)
    assert(base != nil && base.submitted, "worker received an idle task")
    assert(base.run != nil && base.pool != nil, "worker received an unprepared task")

    context.allocator = mem.panic_allocator()
    context.temp_allocator = mem.panic_allocator()

    base.run(base)

    _publish_completed(base.pool, base)
}

// Publish one result without allocating. However many workers finish before the loop runs,
// they share a single dispatcher operation, so nbio's bounded cross-thread queue can never
// make workers wait for this pool's loop while that loop is joining them.
@(private)
_publish_completed :: proc(p: ^Pool, base: ^Task_Base) {
    assert(p != nil && base != nil, "completed publication needs a pool and task")
    assert(base.pool == p && base.submitted, "completed publication crossed pool ownership")
    assert(base.completed_next == nil, "completed task was already queued")

    schedule := false

    sync.mutex_lock(&p.completed_mutex)

    if p.completed_tail == nil {
        assert(p.completed_head == nil, "completed queue lost its tail")
        p.completed_head = base
    } else {
        assert(p.completed_head != nil, "completed queue lost its head")
        p.completed_tail.completed_next = base
    }
    p.completed_tail = base

    if !p.completion_scheduled {
        p.completion_scheduled = true
        schedule = true
    }

    sync.mutex_unlock(&p.completed_mutex)

    if schedule {
        nbio.next_tick_poly(p, _dispatch_completed, p.loop)
    }
}

// Loop thread. Detach one published batch before invoking user completions. A worker that
// finishes while the batch runs creates the next batch and schedules its dispatcher.
@(private)
_dispatch_completed :: proc(op: ^nbio.Operation, p: ^Pool) {
    assert(op != nil && p != nil, "completion dispatcher needs an operation and pool")
    assert(p.loop == nbio.current_thread_event_loop(), "completion dispatcher ran off the pool's loop thread")

    sync.mutex_lock(&p.completed_mutex)

    base := p.completed_head
    assert(base != nil && p.completed_tail != nil, "completion dispatcher found an empty queue")
    assert(p.completion_scheduled, "completion dispatcher fired without being scheduled")
    p.completed_head = nil
    p.completed_tail = nil
    p.completion_scheduled = false

    sync.mutex_unlock(&p.completed_mutex)

    for base != nil {
        next := base.completed_next
        base.completed_next = nil
        _complete(base)
        base = next
    }

    _reap_finished(p)
}

// Loop thread. `done` may free the state the task is embedded in, so everything needed
// afterwards is read out first.
@(private)
_complete :: proc(base: ^Task_Base) {
    assert(base != nil && base.submitted, "completion fired for an idle task")
    assert(base.complete != nil, "completion fired without a trampoline")

    p := base.pool
    assert(p != nil, "completion lost its pool")
    assert(sync.atomic_load(&p.outstanding) > 0, "completion without an outstanding task")

    base.submitted = false

    p.completion_depth += 1
    base.complete(base)
    p.completion_depth -= 1
    assert(p.completion_depth >= 0, "completion depth underflowed")

    sync.atomic_sub(&p.outstanding, 1)
}

// Discard `core:thread`'s record of finished tasks. It retains one entry per task until
// popped, and this pool never reads them, so without this the record grows for the life of
// the process. Best-effort: a worker appends its entry only after returning, which can be
// after this completion runs, so `pool_drain` sweeps again once the workers are joined.
@(private)
_reap_finished :: proc(p: ^Pool) {
    for {
        _, got := thread.pool_pop_done(&p.workers)
        if !got {
            break
        }
    }
}
