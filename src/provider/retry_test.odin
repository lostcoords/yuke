package provider

import "core:testing"
import "core:time"

@(private = "file")
near :: proc(t: ^testing.T, got, want: time.Duration, what: string) {
    delta := got - want
    if delta < 0 do delta = -delta

    testing.expectf(t, delta <= time.Millisecond, "%s: want ~%v, got %v", what, want, got)
}

// Equal jitter: the fixed half plus the whole jittered half, per attempt.
@(test)
test_backoff_growth_bounds :: proc(t: ^testing.T) {
    Case :: struct {
        attempt: int,
        full:    time.Duration,
    }

    cases := [?]Case {
        {1, 3 * time.Second},
        {2, 5400 * time.Millisecond},
        {3, 9720 * time.Millisecond},
        {4, 17496 * time.Millisecond},
        {5, 31492800 * time.Microsecond},
        {6, 56687040 * time.Microsecond},
        // Past the cap.
        {7, RETRY_CAP},
        {8, RETRY_CAP},
        {9, RETRY_CAP},
    }

    for c in cases {
        near(t, retry_backoff(c.attempt, nil, 0), c.full / 2, "floor")
        near(t, retry_backoff(c.attempt, nil, 1), c.full, "ceiling")
        near(t, retry_backoff(c.attempt, nil, 0.5), c.full / 2 + c.full / 4, "midpoint")
    }
}

@(test)
test_backoff_never_exceeds_cap_and_never_shrinks :: proc(t: ^testing.T) {
    previous := time.Duration(0)
    for attempt in 1 ..< RETRY_MAX_ATTEMPTS {
        for jitter in ([?]f64{0, 0.25, 0.5, 0.75, 1}) {
            got := retry_backoff(attempt, nil, jitter)
            testing.expectf(t, got > 0, "attempt %d must wait", attempt)
            testing.expectf(t, got <= RETRY_CAP, "attempt %d must not exceed the cap, got %v", attempt, got)
        }

        got := retry_backoff(attempt, nil, 0.5)
        testing.expectf(t, got >= previous, "attempt %d must not back off less than attempt %d", attempt, attempt - 1)
        previous = got
    }
}

// A provider-named delay wins outright and is used unjittered.
@(test)
test_backoff_honors_retry_after :: proc(t: ^testing.T) {
    for jitter in ([?]f64{0, 0.5, 1}) {
        testing.expect_value(t, retry_backoff(1, 20 * time.Second, jitter), 20 * time.Second)
        testing.expect_value(t, retry_backoff(9, 20 * time.Second, jitter), 20 * time.Second)
        testing.expect_value(t, retry_backoff(1, 0 * time.Second, jitter), 0 * time.Second)
    }

    // Below the computed backoff and still honored: the provider named a time.
    testing.expect_value(t, retry_backoff(6, time.Second, 1), time.Second)
}

@(test)
test_backoff_caps_retry_after :: proc(t: ^testing.T) {
    testing.expect_value(t, retry_backoff(1, RETRY_AFTER_CAP, 0), RETRY_AFTER_CAP)
    testing.expect_value(t, retry_backoff(1, 10 * time.Minute, 0), RETRY_AFTER_CAP)
    testing.expect_value(t, retry_backoff(1, 121 * time.Second, 0), RETRY_AFTER_CAP)
    testing.expect_value(t, retry_backoff(1, 119 * time.Second, 0), 119 * time.Second)
}

@(test)
test_error_retryable :: proc(t: ^testing.T) {
    Case :: struct {
        err:       Transport_Error,
        retryable: bool,
    }

    cases := [?]Case {
        {.None, false},
        {.Invalid_Request, false},
        {.Authentication_Failed, false},
        {.Rate_Limited, true},
        // Terminal: the allowance is gone, so waiting cannot help.
        {.Quota_Exhausted, false},
        {.Server_Error, true},
        {.Network_Error, true},
        {.Parse_Error, false},
        {.Timed_Out, true},
        {.Unsupported_Content_Encoding, false},
        {.Stream_Truncated, true},
        {.Response_Too_Large, false},
        {.Too_Many_Tool_Calls, false},
        {.Tool_Call_Too_Large, false},
        {.Resource_Exhausted, false},
        {.Canceled, false},
    }

    testing.expect_value(t, len(cases), len(Transport_Error))

    for c in cases {
        got := error_retryable(c.err)
        testing.expectf(t, got == c.retryable, "%v retryable must be %v, got %v", c.err, c.retryable, got)
    }
}
