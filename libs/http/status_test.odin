package http

import "core:strconv"
import "core:testing"

// Leading three digits of a status line, or 0 when the entry is too short to hold one.
status_code_of :: proc(status: Status) -> int {
    line := status_wire[status]
    if len(line) < 3 {
        return 0
    }

    code, ok := strconv.parse_int(line[:3])
    if !ok {
        return 0
    }

    return code
}

// A `[Status]string` literal zero-fills forgotten entries, which ship as malformed lines.
@(test)
test_status_wire_is_total :: proc(t: ^testing.T) {
    for status in Status {
        line := status_wire[status]
        testing.expectf(t, len(line) > 4, "%v has no status line", status)
        if len(line) <= 4 {
            continue
        }

        code := status_code_of(status)
        testing.expectf(t, code >= 100 && code <= 599, "%v has a bad code: %q", status, line)
        testing.expectf(t, line[3] == ' ', "%v needs one space after the code: %q", status, line)
    }
}

// Strict ascent catches both a repeated code and a value out of registry order.
@(test)
test_status_codes_are_unique_and_ascending :: proc(t: ^testing.T) {
    previous := 0
    for status in Status {
        code := status_code_of(status)
        testing.expectf(t, code > previous, "%v code %d must exceed the previous %d", status, code, previous)
        previous = code
    }
}

// `respond_redirect` asserts on this, so a targetless 3xx must never pass.
@(test)
test_status_is_redirect_covers_only_location_bearing_3xx :: proc(t: ^testing.T) {
    for status in Status {
        if !status_is_redirect(status) {
            continue
        }

        code := status_code_of(status)
        testing.expectf(t, code >= 300 && code < 400, "%v is not 3xx but reports as a redirect", status)
    }

    testing.expect(t, status_is_redirect(.Found), "302 is the common redirect")
    testing.expect(t, status_is_redirect(.Permanent_Redirect), "308 redirects")
    testing.expect(t, !status_is_redirect(.Not_Modified), "304 names no target")
    testing.expect(t, !status_is_redirect(.Use_Proxy), "305 is deprecated")
    testing.expect(t, !status_is_redirect(.Ok), "200 is not a redirect")
}
