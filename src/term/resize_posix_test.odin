#+build linux, darwin
package term

import "core:sync"
import "core:sys/posix"
import "core:testing"

// `tty` is only stored (re-queried lazily by `wait`), so tests that never call
// `resize_notifier_wait` can pass any placeholder fd.
DUMMY_TTY :: posix.FD(-1)

// `g_write_fd`/`g_active_handlers` and the SIGWINCH disposition are process-wide and the
// test runner runs tests in parallel, so every resize test serializes on this lock.
resize_test_lock: sync.Mutex

@(test)
test_resize_notifier_singleton_and_reclaim :: proc(t: ^testing.T) {
    sync.mutex_lock(&resize_test_lock)
    defer sync.mutex_unlock(&resize_test_lock)

    // A second concurrent init fails while the first notifier is live...
    first, err1 := resize_notifier_init(DUMMY_TTY)
    testing.expect_value(t, err1, Resize_Error.None)

    second, err2 := resize_notifier_init(DUMMY_TTY)
    testing.expect_value(t, err2, Resize_Error.Already_Initialized)
    zero := Resize_Notifier{}
    testing.expect_value(t, second, zero)

    // ...but the slot is reclaimable once the first is torn down.
    resize_notifier_destroy(&first)

    third, err3 := resize_notifier_init(DUMMY_TTY)
    testing.expect_value(t, err3, Resize_Error.None)
    resize_notifier_destroy(&third)
}

@(test)
test_resize_notifier_signal_makes_fd_readable :: proc(t: ^testing.T) {
    sync.mutex_lock(&resize_test_lock)
    defer sync.mutex_unlock(&resize_test_lock)

    n, err := resize_notifier_init(DUMMY_TTY)
    testing.expect_value(t, err, Resize_Error.None)
    defer resize_notifier_destroy(&n)


    // Nothing pending before the signal.
    testing.expect(t, !poll_readable(n.read_fd, 0))

    // A real SIGWINCH runs the actual handler, which writes through the pipe.
    testing.expect_value(t, posix.raise(SIGWINCH), posix.result.OK)
    testing.expect(t, poll_readable(n.read_fd, 200))
}

@(test)
test_resize_notifier_repeated_raises_coalesce :: proc(t: ^testing.T) {
    sync.mutex_lock(&resize_test_lock)
    defer sync.mutex_unlock(&resize_test_lock)

    n, err := resize_notifier_init(DUMMY_TTY)
    testing.expect_value(t, err, Resize_Error.None)
    defer resize_notifier_destroy(&n)

    // A burst of SIGWINCH collapses to one pending byte (EAGAIN on the rest).
    testing.expect_value(t, posix.raise(SIGWINCH), posix.result.OK)
    testing.expect_value(t, posix.raise(SIGWINCH), posix.result.OK)
    testing.expect_value(t, posix.raise(SIGWINCH), posix.result.OK)
    testing.expect(t, poll_readable(n.read_fd, 200))

    drain_pipe(n.read_fd)
    testing.expect(t, !poll_readable(n.read_fd, 50))
}

@(test)
test_resize_notifier_destroy_restores_disposition :: proc(t: ^testing.T) {
    sync.mutex_lock(&resize_test_lock)
    defer sync.mutex_unlock(&resize_test_lock)

    original: posix.sigaction_t
    testing.expect_value(t, posix.sigaction(SIGWINCH, nil, &original), posix.result.OK)

    n, err := resize_notifier_init(DUMMY_TTY)
    testing.expect_value(t, err, Resize_Error.None)
    resize_notifier_destroy(&n)

    restored: posix.sigaction_t
    testing.expect_value(t, posix.sigaction(SIGWINCH, nil, &restored), posix.result.OK)

    // Compare only the handler: glibc stamps SA_RESTORER and a return trampoline into
    // sa_flags/sa_restorer on restore, and sa_mask carries uninitialized padding.
    testing.expect_value(t, restored.sa_handler, original.sa_handler)

    // Re-init after destroy works: the slot and the disposition are both clean.
    n2, err2 := resize_notifier_init(DUMMY_TTY)
    testing.expect_value(t, err2, Resize_Error.None)
    resize_notifier_destroy(&n2)
}

@(test)
test_resize_notifier_wait_propagates_size_query_failure :: proc(t: ^testing.T) {
    sync.mutex_lock(&resize_test_lock)
    defer sync.mutex_unlock(&resize_test_lock)

    // A pipe end is a valid, non-tty fd: TIOCGWINSZ fails on it, so `wait`
    // must surface that failure instead of a bogus size.
    fake_tty: [2]posix.FD
    testing.expect_value(t, posix.pipe(&fake_tty), posix.result.OK)
    defer posix.close(fake_tty[0])
    defer posix.close(fake_tty[1])

    n, err := resize_notifier_init(fake_tty[0])
    testing.expect_value(t, err, Resize_Error.None)
    defer resize_notifier_destroy(&n)

    // Raise first so the pending byte makes `poll` inside `wait` return
    // immediately instead of blocking.
    testing.expect_value(t, posix.raise(SIGWINCH), posix.result.OK)

    size, werr := resize_notifier_wait(&n)
    testing.expect_value(t, werr, Resize_Error.Size_Query_Failed)
    zero := Size{}
    testing.expect_value(t, size, zero)
}

@(test)
test_resize_notifier_consume_drains_and_queries :: proc(t: ^testing.T) {
    sync.mutex_lock(&resize_test_lock)
    defer sync.mutex_unlock(&resize_test_lock)

    fake_tty: [2]posix.FD
    testing.expect_value(t, posix.pipe(&fake_tty), posix.result.OK)
    defer posix.close(fake_tty[0])
    defer posix.close(fake_tty[1])

    n, err := resize_notifier_init(fake_tty[0])
    testing.expect_value(t, err, Resize_Error.None)
    defer resize_notifier_destroy(&n)

    testing.expect_value(t, posix.raise(SIGWINCH), posix.result.OK)
    testing.expect(t, poll_readable(n.read_fd, 200))

    // Fake tty cannot answer TIOCGWINSZ; consume still drains the pipe.
    size, cerr := resize_notifier_consume(&n)
    testing.expect_value(t, cerr, Resize_Error.Size_Query_Failed)
    zero := Size{}
    testing.expect_value(t, size, zero)
    testing.expect(t, !poll_readable(n.read_fd, 50))
}
