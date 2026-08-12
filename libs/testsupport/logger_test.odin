package testsupport

import "base:runtime"
import "core:log"
import "core:testing"

@(private = "file")
Count_Logger :: struct {
    errors: int,
}

@(private = "file")
count_logger_proc :: proc(
    data: rawptr,
    level: log.Level,
    text: string,
    options: log.Options,
    location := #caller_location,
) {
    if level >= .Error {
        (^Count_Logger)(data).errors += 1
    }
}

// Forwards test-authored records (so their failures reach the runner) and drops the
// code-under-test's own logs.
@(test)
test_assert_only_logger_forwards_only_test_authored :: proc(t: ^testing.T) {
    count := Count_Logger{}
    backing := log.Logger{count_logger_proc, &count, .Debug, {}}

    quiet: Assert_Only_Logger
    wrapped := assert_only_logger(&quiet, backing)

    test_loc := runtime.Source_Code_Location {
        file_path = "src/daemon/example_test.odin",
    }
    code_loc := runtime.Source_Code_Location {
        file_path = "src/daemon/daemon.odin",
    }
    support_loc := runtime.Source_Code_Location {
        file_path = "libs/testsupport/nbio.odin",
    }

    wrapped.procedure(wrapped.data, .Error, "assertion failed", {}, test_loc)
    testing.expect_value(t, count.errors, 1)

    wrapped.procedure(wrapped.data, .Error, "daemon: rejected", {}, code_loc)
    testing.expect_value(t, count.errors, 1)

    wrapped.procedure(wrapped.data, .Info, "daemon: listening", {}, code_loc)
    testing.expect_value(t, count.errors, 1)

    wrapped.procedure(wrapped.data, .Error, "wait timed out", {}, support_loc)
    testing.expect_value(t, count.errors, 2)
}
