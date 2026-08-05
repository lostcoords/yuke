package provider

import "core:time"

// Attempts one turn is allowed in total, the first one included. The engine
// owns the counter; the transport is single-attempt.
RETRY_MAX_ATTEMPTS :: 10

// Delay after the first failed attempt, before jitter.
RETRY_BASE :: 3 * time.Second

// Growth factor per attempt.
RETRY_FACTOR :: 1.8

// Ceiling on the computed backoff, before jitter.
RETRY_CAP :: 60 * time.Second

// Ceiling on an honored `Retry-After`. A provider asking for longer is capped
// rather than obeyed, so one hostile or mistaken header cannot park a turn.
RETRY_AFTER_CAP :: 120 * time.Second

// Delay before the next attempt, after `attempt` attempts have failed (1-based).
//
// A provider-supplied `retry_after` wins and is used as given, capped — jitter
// would undercut or overshoot a provider-named time. Otherwise equal jitter
// spreads out a herd of turns that failed together; `jitter` is a
// caller-supplied fraction in `[0, 1]` rather than global rng so the policy
// stays pure.
retry_backoff :: proc(attempt: int, retry_after: Maybe(time.Duration), jitter: f64) -> time.Duration {
    assert(attempt >= 1, "backoff is computed for a failed attempt, so attempt is 1-based")
    assert(attempt < RETRY_MAX_ATTEMPTS, "backoff requires another attempt inside the retry budget")
    assert(jitter >= 0 && jitter <= 1, "jitter must be a fraction of the jittered half")

    if after, present := retry_after.?; present {
        assert(after >= 0, "a negative retry-after must be dropped before it gets here")
        return min(after, RETRY_AFTER_CAP)
    }

    delay := f64(RETRY_BASE)
    for _ in 1 ..< attempt {
        delay *= RETRY_FACTOR

        if delay >= f64(RETRY_CAP) {
            break
        }
    }

    capped := min(time.Duration(delay), RETRY_CAP)
    half := capped / 2
    out := half + time.Duration(f64(capped - half) * jitter)

    assert(out >= 0, "backoff must not be negative")
    assert(out <= RETRY_CAP, "backoff must not exceed the cap")

    return out
}

// May a failed turn be attempted again? `Quota_Exhausted` is deliberately
// terminal — the allowance is gone, and retrying only burns the budget.
error_retryable :: proc(err: Transport_Error) -> bool {
    switch err {
    case .Rate_Limited, .Server_Error, .Network_Error, .Timed_Out, .Stream_Truncated:
        return true

    case .None,
         .Invalid_Request,
         .Authentication_Failed,
         .Quota_Exhausted,
         .Parse_Error,
         .Unsupported_Content_Encoding,
         .Response_Too_Large,
         .Too_Many_Tool_Calls,
         .Tool_Call_Too_Large,
         .Resource_Exhausted,
         .Canceled:
        return false
    }

    return false
}
