//! Decide whether a failed provider attempt may repeat. The decision is pure: no I/O and no state.

use crate::failure::{Failure, ProviderKind};
use crate::response::{AttemptError, Delivery};
use crate::transport::Fault;

/// How a failure behaves for a repeat.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum Class {
    /// The provider answered and named a temporary condition. The request certainly arrived.
    AnsweredTransient,
    /// A 429 that names no known cause, as a rate limit and a spent quota both send. Only a retry delay or
    /// `x-should-retry: true` lets it repeat, as Codex does.
    AnsweredUnknown,
    /// The connection failed. The delivery gate decides whether a repeat is safe.
    Transport,
    /// The retry policy does not repeat this failure.
    NonRetryable,
}

/// How `cause` behaves for a repeat.
fn classify(cause: Failure) -> Class {
    match cause {
        Failure::Provider(kind) => match kind {
            ProviderKind::RateLimited | ProviderKind::ServerError | ProviderKind::Timeout | ProviderKind::Conflict => {
                Class::AnsweredTransient
            }
            ProviderKind::RateLimitUnknown => Class::AnsweredUnknown,
            ProviderKind::AuthFailed
            | ProviderKind::PermissionDenied
            | ProviderKind::QuotaExhausted
            | ProviderKind::BadStatus
            | ProviderKind::ContextOverflow
            | ProviderKind::ProviderFailed => Class::NonRetryable,
        },
        Failure::Transport(fault) => match fault {
            Fault::IdleTimeout
            | Fault::RequestTimeout
            | Fault::ConnectTimeout
            | Fault::ConnectFailed
            | Fault::ConnectionLost
            | Fault::DnsFailed => Class::Transport,
            Fault::InvalidRequest
            | Fault::RedirectRefused
            | Fault::BadUrl
            | Fault::MalformedResponse
            | Fault::TlsSetupFailed => Class::NonRetryable,
        },
        // A stream without its terminal event is a truncation, not a malformed stream.
        Failure::IncompleteStream => Class::Transport,
        // A parse error never repeats.
        Failure::Protocol | Failure::ResponseTooLarge => Class::NonRetryable,
    }
}

/// The bounds of the attempts of one request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Policy {
    /// The most attempts of one request, the first included. At least 1.
    pub max_attempts: u32,
    /// The first computed delay.
    pub base_ms: u64,
    /// The cap for a computed delay. A server delay uses `retry_after_cap_ms`.
    pub cap_ms: u64,
    /// Above this server delay the request stops, so a provider outage never becomes a retry storm.
    pub retry_after_cap_ms: u64,
}

impl Default for Policy {
    fn default() -> Self {
        Policy {
            max_attempts: 5,
            base_ms: 500,
            cap_ms: 8_000,
            retry_after_cap_ms: 120_000,
        }
    }
}

/// Return the delay in milliseconds before the next attempt, or `None` when the request must stop. `number` is the
/// 1-based number of the attempt that failed with `attempt_error`. `jitter` is a draw in `[0, 1)`.
///
/// # Panics
///
/// In a debug build, `decide` panics on input that breaks a precondition: `jitter` outside `[0, 1)`, a `number` of 0,
/// a `policy.max_attempts` of 0, or a `policy.base_ms` above `policy.cap_ms`.
pub fn decide(policy: Policy, attempt_error: &AttemptError, number: u32, jitter: f64) -> Option<u64> {
    debug_assert!(policy.max_attempts >= 1);
    debug_assert!(policy.base_ms <= policy.cap_ms);
    debug_assert!(number >= 1);
    debug_assert!((0.0..1.0).contains(&jitter));

    let info = &attempt_error.info;
    let failure = attempt_error.cause;
    // The caller got an event of the attempt, so a repeat would show it again.
    if info.output_seen {
        return None;
    }
    // The provider's own `x-should-retry` decides first, as both SDKs obey it.
    if info.should_retry == Some(false) {
        return None;
    }
    if info.should_retry != Some(true) {
        match classify(failure) {
            Class::NonRetryable => return None,
            Class::AnsweredUnknown if info.retry_after_ms.is_none() => return None,
            // A transport fault after the first body write leaves delivery uncertain.
            Class::Transport if info.delivery == Delivery::PossiblySent => return None,
            // A provider answered, so it holds the request. Only an explicit HTTP 408 says it did not process it.
            Class::AnsweredTransient
                if failure == Failure::Provider(ProviderKind::Timeout) && info.status != Some(408) =>
            {
                return None;
            }
            _ => {}
        }
    }
    if number >= policy.max_attempts {
        return None;
    }

    let computed = backoff(policy, number, jitter);
    let Some(asked) = info.retry_after_ms else {
        return Some(computed);
    };
    if asked > policy.retry_after_cap_ms {
        return None;
    }
    Some(asked.max(computed)) // A server delay is a floor, so `retry-after: 0` cannot skip the backoff.
}

fn backoff(policy: Policy, number: u32, jitter: f64) -> u64 {
    let shift = (number - 1).min(16);
    let raw = policy.base_ms.saturating_mul(1 << shift);
    #[expect(clippy::cast_precision_loss, reason = "a delay of a few seconds fits f64 exactly")]
    let capped = raw.min(policy.cap_ms) as f64;
    // Keep 75% to 100% of the delay, as the SDKs do. The AWS form `random(0, cap)` differs.
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "the value is a small positive delay"
    )]
    let delay = (capped * (1.0 - jitter * 0.25)) as u64;
    delay
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

    fn decide_with(info: &AttemptInfo, failure: Failure, number: u32) -> Option<u64> {
        decide(Policy::default(), &attempt_error(failure, info.clone()), number, 0.0)
    }

    fn failed(failure: Failure, number: u32) -> Option<u64> {
        decide_with(&AttemptInfo::default(), failure, number)
    }

    // A connection fault or a cut stream repeats. A request that the transport refused to send, or could not secure,
    // fails the same way each time.
    #[test]
    fn transport_failures_repeat_unless_the_request_cannot_leave() {
        let repeats = [
            Fault::ConnectFailed,
            Fault::ConnectTimeout,
            Fault::ConnectionLost,
            Fault::DnsFailed,
            Fault::IdleTimeout,
            Fault::RequestTimeout,
        ]
        .map(Failure::Transport);
        for failure in repeats.into_iter().chain([Failure::IncompleteStream]) {
            assert!(failed(failure, 1).is_some(), "{failure:?}");
        }
        for fault in [Fault::InvalidRequest, Fault::TlsSetupFailed] {
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
        assert_eq!(Some(750), decide(Policy::default(), &server, 2, 0.999));

        // The attempt limit permits both calls, so only the computed delay cap bounds them.
        let policy = Policy {
            max_attempts: 41,
            ..Policy::default()
        };
        for number in [8, 40] {
            assert_eq!(Some(8000), decide(policy, &server, number, 0.0));
        }
    }

    #[test]
    fn shown_output_blocks_retry() {
        let info = AttemptInfo {
            retry_after_ms: Some(10),
            output_seen: true,
            ..AttemptInfo::default()
        };
        assert_eq!(
            None,
            decide_with(&info, Failure::Provider(ProviderKind::RateLimited), 1)
        );
    }

    #[test]
    fn should_retry_header_overrides_class() {
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
    fn possible_delivery_blocks_transport_retry() {
        let cut = Failure::Transport(Fault::ConnectionLost);
        let sent = AttemptInfo {
            delivery: Delivery::PossiblySent,
            ..AttemptInfo::default()
        };
        // No idempotency key exists for either provider, so a repeat could bill the same work twice.
        assert_eq!(None, decide_with(&sent, cut, 1));
        // A proven rate limit permits a repeat even after request delivery.
        assert_eq!(
            Some(500),
            decide_with(&sent, Failure::Provider(ProviderKind::RateLimited), 1)
        );
    }

    #[test]
    fn timeout_answer_retries_only_on_408() {
        for status in [408, 504, 200] {
            // An answer means the provider received the request.
            let info = AttemptInfo {
                status: Some(status),
                delivery: Delivery::PossiblySent,
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
        assert_eq!(None, at(Policy::default().retry_after_cap_ms + 1));
    }

    #[test]
    fn attempt_limit_stops_retries() {
        let server = Failure::Provider(ProviderKind::ServerError);
        assert_eq!(Some(4000), failed(server, 4));
        assert_eq!(None, failed(server, 5));
    }
}
