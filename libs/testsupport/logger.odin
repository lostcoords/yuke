package testsupport

import "core:log"
import "core:strings"

// Assert_Only_Logger drops the code-under-test's own records (noise, and error-level ones the
// runner miscounts as failures) but forwards records from a `*_test.odin` or testsupport
// location, keeping `testing.expect` failures counted. Replaces log.nil_logger() at test scope.
//
//	saved := context.logger
//	quiet: testsupport.Assert_Only_Logger
//	context.logger = testsupport.assert_only_logger(&quiet, saved)
//	defer context.logger = saved
Assert_Only_Logger :: struct {
    backing: log.Logger,
}

assert_only_logger :: proc(self: ^Assert_Only_Logger, backing: log.Logger) -> log.Logger {
    assert(self != nil, "an assert-only logger needs backing storage")
    self.backing = backing

    return {
        procedure = assert_only_logger_proc,
        data = self,
        lowest_level = backing.lowest_level,
        options = backing.options,
    }
}

// Forward only test-authored records (a `_test.odin` or testsupport location); the code under
// test never logs from either, so its records drop.
@(private = "file")
assert_only_logger_proc :: proc(
    data: rawptr,
    level: log.Level,
    text: string,
    options: log.Options,
    location := #caller_location,
) {
    self := (^Assert_Only_Logger)(data)
    if self == nil || self.backing.procedure == nil {
        return
    }

    test_authored :=
        strings.has_suffix(location.file_path, "_test.odin") || strings.contains(location.file_path, "testsupport")
    if !test_authored {
        return
    }

    self.backing.procedure(self.backing.data, level, text, options, location)
}
