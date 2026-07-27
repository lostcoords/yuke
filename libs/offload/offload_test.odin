package offload

import "core:nbio"
import "core:sync"
import "core:testing"
import "core:thread"
import ts "libs:testsupport"

// Offloaded state: the task rides inside it, so no task is allocated per submission.
Job :: struct {
    task:      Task(Job),

    // Input the worker reads; owned here, never borrowed.
    input:     int,

    // Filled on the worker thread.
    output:    int,

    // Thread the work ran on, to prove it left the loop thread.
    work_tid:  int,

    // Thread the completion ran on, to prove it came back.
    done_tid:  int,

    // Set by the completion.
    completed: bool,
}

job_work :: proc(j: ^Job) {
    j.output = j.input * 2
    j.work_tid = sync.current_thread_id()
}

job_done :: proc(j: ^Job) {
    j.done_tid = sync.current_thread_id()
    j.completed = true
}

job_completed :: proc(j: ^Job) -> bool {
    return j.completed
}

@(test)
test_offload_runs_off_loop_and_completes_on_it :: proc(t: ^testing.T) {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    pool: Pool
    testing.expect_value(t, pool_init(&pool, loop, 2), Error.None)

    loop_tid := sync.current_thread_id()

    job := Job {
        input = 21,
    }
    submit(&pool, &job.task, &job, job_work, job_done)
    testing.expect_value(t, pool_outstanding(&pool), 1)

    if !ts.nbio_run_until(t, &job, job_completed, "offloaded job completes") {
        return
    }

    testing.expect_value(t, job.output, 42)
    testing.expect(t, job.work_tid != loop_tid, "work must not run on the loop thread")
    testing.expect_value(t, job.done_tid, loop_tid)
    testing.expect_value(t, pool_outstanding(&pool), 0)

    testing.expect_value(t, pool_drain(&pool), nil)
    pool_destroy(&pool)
}

// Many tasks over few workers: every completion must arrive, and the pool must land back
// on zero outstanding.
@(test)
test_offload_completes_every_task :: proc(t: ^testing.T) {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    pool: Pool
    testing.expect_value(t, pool_init(&pool, loop, 2), Error.None)

    JOBS :: 32
    jobs: [JOBS]Job
    for &job, i in jobs {
        job.input = i
        submit(&pool, &job.task, &job, job_work, job_done)
    }

    testing.expect_value(t, pool_outstanding(&pool), JOBS)

    testing.expect_value(t, pool_drain(&pool), nil)
    testing.expect_value(t, pool_outstanding(&pool), 0)

    for &job, i in jobs {
        testing.expectf(t, job.completed, "job %d never completed", i)
        testing.expect_value(t, job.output, i * 2)
    }

    // `core:thread` retains one record per finished task until it is popped. Left alone it
    // grows for the life of the process, so the pool must reap it.
    testing.expect_value(t, thread.pool_num_done(&pool.workers), 0)

    pool_destroy(&pool)
}

// A drain with nothing in flight still has to join the workers and leave the pool
// destroyable.
@(test)
test_offload_drain_when_idle :: proc(t: ^testing.T) {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    pool: Pool
    testing.expect_value(t, pool_init(&pool, loop, 1), Error.None)
    testing.expect_value(t, pool_outstanding(&pool), 0)

    testing.expect_value(t, pool_drain(&pool), nil)
    pool_destroy(&pool)
}

@(test)
test_offload_rejects_bad_options :: proc(t: ^testing.T) {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    pool: Pool
    testing.expect_value(t, pool_init(&pool, loop, 0), Error.Invalid_Options)
    testing.expect_value(t, pool_init(&pool, nil, 1), Error.Invalid_Options)
}
