package offload

import "core:mem"
import "core:nbio"
import "core:sync"
import "core:thread"
import "core:time"

// Per-tick wait while draining. The drain loop itself terminates because the workers are
// joined before it runs, so the number of completions left to deliver is fixed; the bound
// only keeps a single tick from blocking indefinitely if a backend has nothing to report.
DRAIN_TICK :: 10 * time.Millisecond

Error :: enum {
    None,
    Invalid_Options,
}

// Type-erased head of every task, so one worker entry point can drive any `Task(T)`.
// Kept at offset zero: the worker recovers it from the queued pointer.
Task_Base :: struct {
    // @private
    pool:      ^Pool,

    // @private
    // Set between `submit` and `done`; guards against submitting twice.
    submitted: bool,

    // @private
    // Monomorphic trampolines written by `submit`, which recover the typed state.
    run:       proc(base: ^Task_Base),
    complete:  proc(base: ^Task_Base),
}

// One in-flight offload. Embedded in the state it carries, so the task itself is never
// allocated per submission. `core:thread` still owns the queue `submit` pushes onto, which
// grows on demand, so submitting is cheap rather than allocation-free.
Task :: struct($T: typeid) {
    using base: Task_Base,

    // @private
    state:      ^T,

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
    loop:        ^nbio.Event_Loop,

    // @private
    workers:     thread.Pool,

    // @private
    allocator:   mem.Allocator,

    // @private
    // Tasks between `submit` and `done`. Written from a worker and from the loop thread,
    // so only ever through atomics.
    outstanding: int,

    // @private
    // Cleared by `pool_drain`; submitting past that point is a bug.
    accepting:   bool,
}

// Start `worker_count` threads bound to `loop`. Blocking work waits on syscalls rather
// than competing for cores, so a small count is usually the right one.
pool_init :: proc(p: ^Pool, loop: ^nbio.Event_Loop, worker_count: int, allocator := context.allocator) -> Error {
    if p == nil || loop == nil || worker_count <= 0 {
        return .Invalid_Options
    }

    p^ = {}
    p.loop = loop
    p.allocator = allocator

    thread.pool_init(&p.workers, allocator, worker_count)
    thread.pool_start(&p.workers)
    p.accepting = true

    assert(p.accepting && p.outstanding == 0, "a fresh pool owes no completions")

    return .None
}

// Hand `state` to a worker: `work` runs there, then `done` runs on the pool's loop.
// `task` must stay alive until `done` returns, which is why it belongs inside `state`.
// Once submitted the task cannot be cancelled, so `done` will run even if the requester
// is gone by then.
submit :: proc(p: ^Pool, task: ^Task($T), state: ^T, work: proc(state: ^T), done: proc(state: ^T)) {
    assert(p != nil && task != nil && state != nil, "offload needs a pool, a task, and state")
    assert(work != nil && done != nil, "offload needs both a work and a done procedure")
    assert(p.accepting, "offload submitted after the pool was drained")
    assert(!task.submitted, "offload task submitted while already in flight")

    task.pool = p
    task.state = state
    task.work = work
    task.done = done
    task.submitted = true

    task.run = proc(base: ^Task_Base) {
        t := (^Task(T))(base)
        t.work(t.state)
    }

    task.complete = proc(base: ^Task_Base) {
        t := (^Task(T))(base)
        t.done(t.state)
    }

    sync.atomic_add(&p.outstanding, 1)
    thread.pool_add_task(&p.workers, p.allocator, _run, &task.base)
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

// Finish queued work, join the workers, then run every completion still queued on the
// loop. Must run on the pool's loop thread, since that is where completions fire.
//
// `thread.pool_finish` runs whatever is still queued on the calling thread, so a `work`
// procedure may execute on the loop thread during a drain.
pool_drain :: proc(p: ^Pool) -> nbio.General_Error {
    assert(p != nil, "drain needs a pool")
    assert(p.loop == nbio.current_thread_event_loop(), "drain ran off the pool's loop thread")

    p.accepting = false
    thread.pool_finish(&p.workers)

    for sync.atomic_load(&p.outstanding) > 0 {
        if err := nbio.tick(DRAIN_TICK); err != nil {
            return err
        }
    }

    // The workers are joined, so every entry they owed has been recorded by now.
    _reap_finished(p)

    return nil
}

// Release the pool. `pool_drain` must have run first: destroying with completions
// outstanding would leave a worker's result with nowhere to land.
pool_destroy :: proc(p: ^Pool) {
    assert(p != nil, "destroy needs a pool")
    assert(!p.accepting, "pool destroyed before it was drained")
    assert(sync.atomic_load(&p.outstanding) == 0, "pool destroyed with completions outstanding")

    thread.pool_destroy(&p.workers)
    p^ = {}
}

// Worker thread. Runs the blocking half, then hands the completion back to the loop.
//
// `core:thread` installs the pool's allocator as this thread's `context.allocator`, which
// is the submitting thread's allocator and the one `work` must not touch. Both context
// allocators are replaced with a panicking one so an accidental implicit allocation fails
// here instead of racing whoever owns them.
@(private)
_run :: proc(t: thread.Task) {
    base := (^Task_Base)(t.data)
    assert(base != nil && base.submitted, "worker received an idle task")
    assert(base.run != nil && base.pool != nil, "worker received an unprepared task")

    context.allocator = mem.panic_allocator()
    context.temp_allocator = mem.panic_allocator()

    base.run(base)

    nbio.next_tick_poly(base, _complete, base.pool.loop)
}

// Loop thread. `done` may free the state the task is embedded in, so everything needed
// afterwards is read out first.
@(private)
_complete :: proc(op: ^nbio.Operation, base: ^Task_Base) {
    assert(base != nil && base.submitted, "completion fired for an idle task")
    assert(base.complete != nil, "completion fired without a trampoline")

    p := base.pool
    assert(p != nil, "completion lost its pool")
    assert(sync.atomic_load(&p.outstanding) > 0, "completion without an outstanding task")

    base.submitted = false
    base.complete(base)

    sync.atomic_sub(&p.outstanding, 1)
    _reap_finished(p)
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
