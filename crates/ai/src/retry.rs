//! Decide whether a failed provider attempt may repeat. The decision is pure: no I/O and no state.

use std::num::NonZeroU32;
use std::time::Duration;

use crate::failure::{Failure, ProviderKind};
use crate::response::{AttemptError, AttemptInfo};
use crate::transport::Fault;

/// Whether `cause` may repeat without `x-should-retry: true`. A provider timeout also needs status 408, and an unknown
/// 429 needs a retry delay. A repeat can duplicate a request, because neither provider takes an idempotency key.
fn repeatable(cause: Failure, info: &AttemptInfo) -> bool {
    match cause {
        Failure::Provider(kind) => match kind {
            ProviderKind::RateLimited | ProviderKind::ServerError | ProviderKind::Conflict => true,
            // A provider answered, so it holds the request. Only an explicit HTTP 408 says it did not process it.
            ProviderKind::Timeout => info.status == Some(408),
            // A 429 that names no known cause, as a rate limit and a spent quota both send. Only a retry delay lets it
            // repeat, as Codex does.
            ProviderKind::RateLimitUnknown => info.retry_after_ms.is_some(),
            ProviderKind::AuthFailed
            | ProviderKind::PermissionDenied
            | ProviderKind::QuotaExhausted
            | ProviderKind::BadStatus
            | ProviderKind::ContextOverflow
            | ProviderKind::ProviderFailed => false,
        },
        Failure::Transport(fault) => match fault {
            Fault::IdleTimeout
            | Fault::RequestTimeout
            | Fault::ConnectFailed
            | Fault::ConnectTimeout
            | Fault::ConnectionLost
            | Fault::DnsFailed => true,
            Fault::InvalidRequest
            | Fault::RedirectRefused
            | Fault::BadUrl
            | Fault::MalformedResponse
            | Fault::AnswerTooLarge
            | Fault::TlsSetupFailed
            // The same certificate fails the check again.
            | Fault::CertificateRejected => false,
        },
        // A stream without its terminal event is a truncation, not a malformed stream.
        Failure::IncompleteStream => true,
        // A parse error never repeats.
        Failure::Protocol | Failure::ResponseTooLarge => false,
    }
}

/// The bounds of the attempts of one request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Policy {
    /// The most attempts of one request, the first included.
    pub max_attempts: NonZeroU32,
    /// The first computed delay. A base above `cap` waits `cap`.
    pub base: Duration,
    /// The cap for a computed delay. A server delay uses `retry_after_cap`.
    pub cap: Duration,
    /// Above this server delay the request stops, so a provider outage never becomes a retry storm.
    pub retry_after_cap: Duration,
}

impl Default for Policy {
    fn default() -> Self {
        Policy {
            max_attempts: NonZeroU32::new(5).unwrap_or(NonZeroU32::MIN),
            base: Duration::from_millis(500),
            cap: Duration::from_secs(8),
            retry_after_cap: Duration::from_secs(120),
        }
    }
}

/// Return the delay before the next attempt, or `None` when the request must stop.
/// `number` is the number of the attempt that failed with `attempt_error`, from 1.
/// `jitter` is a draw in `[0, 1)`.
pub fn decide(policy: Policy, attempt_error: &AttemptError, number: NonZeroU32, jitter: f64) -> Option<Duration> {
    let info = &attempt_error.info;
    // The caller got an event of the attempt, so a repeat would show it again.
    if info.output_seen {
        return None;
    }
    // The same input never fits the window, so not even `x-should-retry` repeats it. A hook can shrink it instead.
    if attempt_error.cause == Failure::Provider(ProviderKind::ContextOverflow) {
        return None;
    }
    // The provider's own `x-should-retry` decides first, as both SDKs obey it.
    if info.should_retry == Some(false) {
        return None;
    }
    if info.should_retry != Some(true) && !repeatable(attempt_error.cause, info) {
        return None;
    }
    if number >= policy.max_attempts {
        return None;
    }

    let computed = backoff(policy, number, jitter);
    let Some(asked) = info.retry_after_ms.map(Duration::from_millis) else {
        return Some(computed);
    };
    if asked > policy.retry_after_cap {
        return None;
    }
    Some(asked.max(computed)) // A server delay is a floor, so `retry-after: 0` cannot skip the backoff.
}

fn backoff(policy: Policy, number: NonZeroU32, jitter: f64) -> Duration {
    let shift = (number.get() - 1).min(16);
    let capped = policy.base.saturating_mul(1 << shift).min(policy.cap);
    // Keep 75% to 100% of the delay, as the SDKs do. The AWS form `random(0, cap)` differs. A cut of at most a quarter
    // cannot overflow.
    capped.saturating_sub(capped.mul_f64(jitter * 0.25))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::response::AttemptInfo;

    fn attempt_error(cause: Failure, info: AttemptInfo) -> AttemptError {
        AttemptError {
            cause,
            info,
            partial: Vec::new(),
        }
    }

    fn nth(number: u32) -> NonZeroU32 {
        NonZeroU32::new(number).unwrap()
    }

    /// The delay in milliseconds, so the expected values read as plain numbers.
    fn millis(delay: Option<Duration>) -> Option<u64> {
        delay.map(|delay| u64::try_from(delay.as_millis()).unwrap())
    }

    fn decide_with(info: &AttemptInfo, failure: Failure, number: u32) -> Option<u64> {
        millis(decide(
            Policy::default(),
            &attempt_error(failure, info.clone()),
            nth(number),
            0.0,
        ))
    }

    fn failed(failure: Failure, number: u32) -> Option<u64> {
        decide_with(&AttemptInfo::default(), failure, number)
    }

    // A connection fault or a cut stream can pass, so it repeats. A request that the transport refused to send, or
    // could not secure, fails the same way each time, so it does not repeat.
    #[test]
    fn transport_failures_repeat_unless_they_fail_the_same_way_each_time() {
        let repeats = [
            Fault::ConnectFailed,
            Fault::ConnectionLost,
            Fault::DnsFailed,
            Fault::IdleTimeout,
            Fault::RequestTimeout,
        ]
        .map(Failure::Transport);
        for failure in repeats.into_iter().chain([Failure::IncompleteStream]) {
            assert_eq!(failed(failure, 1), Some(500), "{failure:?}");
        }
        for fault in [Fault::InvalidRequest, Fault::TlsSetupFailed, Fault::CertificateRejected] {
            assert_eq!(failed(Failure::Transport(fault), 1), None, "{fault:?}");
        }
    }

    #[test]
    fn transient_answer_retries_with_capped_backoff() {
        assert_eq!(Some(500), failed(Failure::Provider(ProviderKind::RateLimited), 1));
        assert_eq!(Some(1000), failed(Failure::Provider(ProviderKind::ServerError), 2));
        assert_eq!(Some(500), failed(Failure::Provider(ProviderKind::Conflict), 1));
        // The jitter removes at most a quarter, so a full draw leaves 750 of 1000.
        let server = attempt_error(Failure::Provider(ProviderKind::ServerError), AttemptInfo::default());
        assert_eq!(Some(750), millis(decide(Policy::default(), &server, nth(2), 0.999)));

        // The attempt limit permits both calls, so only the computed delay cap bounds them.
        let policy = Policy {
            max_attempts: nth(41),
            ..Policy::default()
        };
        for number in [8, 40] {
            assert_eq!(Some(8000), millis(decide(policy, &server, nth(number), 0.0)));
        }

        // A base above the cap waits the cap.
        let inverted = Policy {
            base: Duration::from_secs(10),
            cap: Duration::from_secs(2),
            ..Policy::default()
        };
        assert_eq!(Some(2000), millis(decide(inverted, &server, nth(1), 0.0)));
        let largest = Policy {
            base: Duration::MAX,
            cap: Duration::MAX,
            ..Policy::default()
        };
        assert!(decide(largest, &server, nth(1), 0.0).is_some());
    }

    #[test]
    fn shown_output_blocks_retry() {
        let info = AttemptInfo {
            retry_after_ms: Some(10),
            output_seen: true,
            ..AttemptInfo::default()
        };
        for failure in [
            Failure::Provider(ProviderKind::RateLimited),
            Failure::Transport(Fault::ConnectionLost),
        ] {
            assert_eq!(None, decide_with(&info, failure, 1), "{failure:?}");
        }
    }

    #[test]
    fn should_retry_header_overrides_the_kind_of_the_failure_except_an_overflow() {
        assert_eq!(None, failed(Failure::Provider(ProviderKind::AuthFailed), 1));
        let vetoed = AttemptInfo {
            should_retry: Some(false),
            ..AttemptInfo::default()
        };
        assert_eq!(
            None,
            decide_with(&vetoed, Failure::Provider(ProviderKind::ServerError), 1)
        );
        let asked = AttemptInfo {
            should_retry: Some(true),
            ..AttemptInfo::default()
        };
        assert_eq!(
            Some(500),
            decide_with(&asked, Failure::Provider(ProviderKind::AuthFailed), 1)
        );
        assert_eq!(
            None,
            decide_with(&asked, Failure::Provider(ProviderKind::ContextOverflow), 1)
        );
    }

    // opencode Zen answers a rate limit with `RateLimitError` and Mistral with a body of its own, so neither names a
    // code we know. Codex retries such a 429 only on the server's delay (openai/codex#49441).
    #[test]
    fn unknown_429_retries_only_on_provider_advice() {
        let unknown = Failure::Provider(ProviderKind::RateLimitUnknown);
        assert_eq!(None, failed(unknown, 1));
        let delayed = AttemptInfo {
            retry_after_ms: Some(2_000),
            ..AttemptInfo::default()
        };
        assert_eq!(Some(2_000), decide_with(&delayed, unknown, 1));
        let asked = AttemptInfo {
            should_retry: Some(true),
            ..AttemptInfo::default()
        };
        assert_eq!(Some(500), decide_with(&asked, unknown, 1));
    }

    #[test]
    fn timeout_answer_retries_only_on_408() {
        for status in [408, 504, 200] {
            // An answer means the provider received the request.
            let info = AttemptInfo {
                status: Some(status),
                ..AttemptInfo::default()
            };
            let expected = (status == 408).then_some(500);
            assert_eq!(
                expected,
                decide_with(&info, Failure::Provider(ProviderKind::Timeout), 1)
            );
        }
    }

    #[test]
    fn server_delay_is_a_floor() {
        let limited = Failure::Provider(ProviderKind::RateLimited);
        let at = |ms| {
            decide_with(
                &AttemptInfo {
                    retry_after_ms: Some(ms),
                    ..AttemptInfo::default()
                },
                limited,
                1,
            )
        };
        assert_eq!(Some(2_500), at(2_500));
        // A provider sent `retry-after: 0`, and five attempts fired within 8 ms.
        assert_eq!(Some(500), at(0));
        // Above the cap the request stops. It must not fall back to a shorter local delay.
        let cap = u64::try_from(Policy::default().retry_after_cap.as_millis()).unwrap();
        assert_eq!(None, at(cap + 1));
    }

    #[test]
    fn attempt_limit_stops_retries() {
        let server = Failure::Provider(ProviderKind::ServerError);
        assert_eq!(Some(4000), failed(server, 4));
        assert_eq!(None, failed(server, 5));
    }
}
