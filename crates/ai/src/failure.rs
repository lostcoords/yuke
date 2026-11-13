//! What went wrong in one attempt: the provider's answer or a failed exchange, and what the caller can be told.

use std::fmt;
use std::fmt::Write as _;

use crate::json::{self, Value};
use crate::transport::Fault;

/// The provider answered with an error. A status and a stream event map into this one set.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ProviderKind {
    /// The provider returned status 401.
    AuthFailed,
    /// The provider returned status 403.
    PermissionDenied,
    /// The provider returned status 429 with a code that proves a temporary rate limit, or that code in a stream.
    RateLimited,
    /// The provider returned status 402, or a quota, credit, or spend code.
    QuotaExhausted,
    /// The provider returned status 429 with no code that proves its cause.
    RateLimitUnknown,
    /// The provider returned a 5xx status, or an overload or server error code.
    ServerError,
    /// The provider returned another status than 200.
    BadStatus,
    /// The provider returned status 408 or 504, or a timeout code.
    Timeout,
    /// The provider returned status 409 or a conflict code. The official OpenAI and Anthropic SDKs retry the request.
    Conflict,
    /// The provider reports that the input exceeds the model context window.
    ContextOverflow,
    /// The provider reported an error that no other kind names.
    ProviderFailed,
}

impl fmt::Display for ProviderKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::AuthFailed => "the provider rejected the credential",
            Self::PermissionDenied => "the provider denied permission for this request",
            Self::RateLimited => "the provider rate limit stopped the request",
            Self::QuotaExhausted => "the provider account has no quota left",
            Self::RateLimitUnknown => "the provider returned a 429 response with no known cause",
            Self::ServerError => "the provider returned a server error",
            Self::BadStatus => "the provider returned an unexpected status",
            Self::Timeout => "the provider reported a timeout",
            Self::Conflict => "the provider reported a conflict",
            Self::ContextOverflow => "the provider reports that the input exceeds the model context window",
            Self::ProviderFailed => "the provider reported an error",
        })
    }
}

/// One failed attempt. It holds no strings. The attempt facts live in [`crate::AttemptInfo`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Failure {
    /// The provider answered with an error.
    Provider(ProviderKind),

    /// The transport failed.
    Transport(Fault),

    /// The stream broke the protocol.
    Protocol,

    /// The response exceeded a bound in [`crate::ResponseLimits`].
    ResponseTooLarge,

    /// The stream ended before its terminal event.
    IncompleteStream,
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Provider(kind) => fmt::Display::fmt(kind, f),
            Self::Transport(fault) => fmt::Display::fmt(fault, f),
            Self::Protocol => f.write_str("the provider sent a malformed stream"),
            Self::ResponseTooLarge => f.write_str("the provider response exceeds a configured limit"),
            Self::IncompleteStream => f.write_str("the provider stream ended early"),
        }
    }
}

impl std::error::Error for Failure {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            // The text is the text of the inner error, so the source is the source of the inner error.
            Self::Transport(fault) => fault.source(),
            _ => None,
        }
    }
}

/// The kind of a non-200 answer from its status and body bytes.
pub(crate) fn status_kind(status: u16, body: Option<&[u8]>) -> ProviderKind {
    debug_assert!(status != 200);
    let named = json::parse_bytes(body.unwrap_or_default())
        .ok()
        .and_then(|root| Fields::read(&root)?.classify());
    // A spent limit wins over the status: a spend cap shares 429, and opencode Zen answers spent credit with 401.
    if named == Some(ProviderKind::QuotaExhausted) {
        return ProviderKind::QuotaExhausted;
    }
    if status == 429 {
        return if named == Some(ProviderKind::RateLimited) {
            ProviderKind::RateLimited
        } else {
            ProviderKind::RateLimitUnknown
        };
    }
    let by_status = by_status(status);
    if by_status == ProviderKind::BadStatus && named == Some(ProviderKind::ContextOverflow) {
        return ProviderKind::ContextOverflow;
    }
    by_status
}

/// The kind of one parsed stream error event. An event that names no known code is a generic provider failure.
pub(crate) fn event_kind(root: &Value<'_>) -> ProviderKind {
    Fields::read(root)
        .and_then(|fields| fields.classify())
        .unwrap_or(ProviderKind::ProviderFailed)
}

/// Build a sanitized line from error answer bytes: `type: message (code)` when the JSON names them, else
/// the raw text. `None` when nothing printable remains.
pub(crate) fn detail_text(bytes: &[u8]) -> Option<String> {
    let described = json::parse_bytes(bytes).ok().and_then(|root| describe(&root));
    let line = described.as_ref().map_or(bytes, String::as_bytes);
    // `sanitize` turns the C0, DEL, and C1 characters into spaces, so this trim also drops edge tabs and line ends.
    let clean = sanitize(line);
    let clean = clean.trim_matches(' ');
    if clean.is_empty() { None } else { Some(clean.to_owned()) }
}

/// Hold the error fields of one answer, because each dialect puts them in another place.
#[derive(Default)]
struct Fields<'v> {
    kind: Option<&'v str>,
    code: Option<&'v str>,
    /// OpenRouter puts its stable error class here, whatever API format it serves.
    error_type: Option<&'v str>,
    /// A gateway uses a numeric code to repeat the upstream status.
    status: Option<i64>,
    message: Option<&'v str>,
    /// Anthropic names a spend limit here under a rate-limit type.
    detail_code: Option<&'v str>,
}

impl<'v> Fields<'v> {
    /// Find the error fields: `error` (a body or a chunk), `response.error` (`response.failed`), or the root of a
    /// flat `error` event.
    fn read(root: &'v Value<'_>) -> Option<Self> {
        if let Some(value) = root.get("error") {
            match value {
                Value::String(text) => {
                    return Some(Fields {
                        message: Some(text),
                        ..Fields::default()
                    });
                }
                Value::Object(_) => return Some(Fields::of(value)),
                _ => {}
            }
        }
        if let Some(response) = root.get("response") {
            let mut fields = response.get("error").map(Fields::of).unwrap_or_default();
            // OpenRouter puts the class of a failed response beside the error object.
            fields.error_type = response.get_str("error_type").or(fields.error_type);
            return Some(fields);
        }
        if root.get_str("type") == Some("error") {
            return Some(Fields::of(root));
        }
        None
    }

    /// Read the fields of one error object. Any other value names no field.
    fn of(value: &'v Value<'_>) -> Self {
        Fields {
            kind: value.get_str("type"),
            code: value.get_str("code"),
            error_type: value
                .get_str("error_type")
                .or_else(|| value.get("metadata")?.get_str("error_type")),
            status: value.get_int("code"),
            message: value.get_str("message"),
            detail_code: value.get("details").and_then(|details| details.get_str("error_code")),
        }
    }

    fn classify(&self) -> Option<ProviderKind> {
        let names = [self.code, self.error_type, self.kind, self.detail_code];
        // A spend cap can share a rate-limit type, so a quota name wins over every other name.
        if names.iter().flatten().any(|name| is_quota_code(name)) {
            return Some(ProviderKind::QuotaExhausted);
        }
        if let Some(kind) = names.iter().flatten().find_map(|name| by_name(name)) {
            return Some(kind);
        }
        // Anthropic names an input over the context window only in the message of a general request error.
        if self.kind == Some("invalid_request_error")
            && self
                .message
                .is_some_and(|message| message.starts_with("prompt is too long"))
        {
            return Some(ProviderKind::ContextOverflow);
        }
        let status = u16::try_from(self.status?).ok()?;
        if status < 400 {
            return None;
        }
        Some(by_status(status)).filter(|kind| *kind != ProviderKind::BadStatus)
    }
}

/// Map an OpenAI `code`, an OpenRouter `error_type`, or an Anthropic `type` onto the answer set.
fn by_name(name: &str) -> Option<ProviderKind> {
    Some(match name {
        "context_length_exceeded" => ProviderKind::ContextOverflow,
        "rate_limit_exceeded" | "slow_down" | "rate_limit_error" => ProviderKind::RateLimited,
        "server_error"
        | "server_is_overloaded"
        | "api_error"
        | "overloaded_error"
        | "provider_overloaded"
        | "provider_unavailable"
        | "server" => ProviderKind::ServerError,
        "timeout" | "timeout_error" => ProviderKind::Timeout,
        "conflict" | "conflict_error" => ProviderKind::Conflict,
        "authentication" | "authentication_error" => ProviderKind::AuthFailed,
        "permission_denied" | "permission_error" => ProviderKind::PermissionDenied,
        _ => return None,
    })
}

/// Map a status, and require proof before a 429 can repeat.
fn by_status(status: u16) -> ProviderKind {
    match status {
        401 => ProviderKind::AuthFailed,
        402 => ProviderKind::QuotaExhausted,
        403 => ProviderKind::PermissionDenied,
        408 | 504 => ProviderKind::Timeout,
        // The official OpenAI and Anthropic SDKs repeat a 409.
        409 => ProviderKind::Conflict,
        429 => ProviderKind::RateLimitUnknown,
        // 504 matched the timeout arm above.
        500..=599 => ProviderKind::ServerError,
        _ => ProviderKind::BadStatus,
    }
}

/// The provider error names of an exhausted quota, credit, usage, or spend limit. A repeat cannot succeed before the
/// limit resets, whatever the status.
fn is_quota_code(code: &str) -> bool {
    matches!(
        code,
        "insufficient_quota"
            | "payment_required"
            | "billing_error"
            | "enforced_spend_limit_reached"
            | "credit_balance_exhausted"
            | "organization_usage_limit_exceeded"
            // The ChatGPT Codex backend, as Codex CLI reads it (codex-rs/codex-api/src/api_bridge.rs).
            | "usage_limit_reached"
            | "usage_not_included"
            | "subscription_sharing_usage_limit_exceeded"
            // opencode Zen, whose errors carry their class name (packages/console/app/src/routes/zen/util/handler.ts).
            | "FreeUsageLimitError"
            | "GoUsageLimitError"
            | "CreditsError"
            | "MonthlyLimitError"
            | "UserLimitError"
    ) || code.ends_with("_spend_limit_exceeded")
}

/// Write `type: message (code)`, or `None` when the answer names no message.
fn describe(root: &Value<'_>) -> Option<String> {
    let fields = Fields::read(root)?;
    let message = fields.message?;
    let mut out = String::new();
    if let Some(kind) = fields.kind
        && kind != "error"
    {
        out.push_str(kind);
        out.push_str(": ");
    }
    out.push_str(message);
    if let Some(code) = fields.code {
        out.push_str(" (");
        out.push_str(code);
        out.push(')');
    } else if let Some(status) = fields.status {
        _ = write!(out, " ({status})"); // A String never fails a write.
    }
    Some(out)
}

/// Copy the text as valid UTF-8: a C0, DEL, or C1 control becomes a space and an invalid byte becomes `?`.
fn sanitize(text: &[u8]) -> String {
    let mut out = String::with_capacity(text.len());
    for chunk in text.utf8_chunks() {
        for c in chunk.valid().chars() {
            let control = c < ' ' || c == '\u{7f}' || ('\u{80}'..'\u{a0}').contains(&c);
            out.push(if control { ' ' } else { c });
        }
        out.extend(chunk.invalid().iter().map(|_| '?'));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(bytes: &str) -> ProviderKind {
        event_kind(&json::parse(bytes).unwrap())
    }

    #[test]
    fn event_kind_reads_each_dialects_error_shape() {
        use ProviderKind::*;
        // Responses `response.failed`: the error sits under `response`.
        assert_eq!(
            RateLimited,
            event(
                r#"{"type":"response.failed","response":{"status":"failed","error":{"code":"rate_limit_exceeded","message":"try again"}}}"#
            )
        );
        assert_eq!(
            ContextOverflow,
            event(
                r#"{"type":"response.failed","response":{"error":{"code":"context_length_exceeded","message":"too long"}}}"#
            )
        );
        assert_eq!(
            ServerError,
            event(
                r#"{"type":"response.failed","response":{"error":{"code":"server_is_overloaded","message":"busy"}}}"#
            )
        );
        // Responses `error`: the fields sit at the root.
        assert_eq!(
            QuotaExhausted,
            event(
                r#"{"type":"error","code":"insufficient_quota","message":"no credit","param":null,"sequence_number":2}"#
            )
        );
        // Anthropic `error`: a conflict in the stream is the 409 of a plain answer.
        assert_eq!(
            Conflict,
            event(r#"{"type":"error","error":{"type":"conflict_error","message":"busy"}}"#)
        );
        // Anthropic `error`: an overload in the stream is the 529 of a plain answer.
        assert_eq!(
            ServerError,
            event(r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        );
        // An OpenRouter chunk repeats the upstream status as a number, and a 429 without proof never repeats.
        assert_eq!(
            RateLimitUnknown,
            event(r#"{"error":{"code":429,"message":"Rate limit exceeded"},"choices":[]}"#)
        );
        assert_eq!(ServerError, event(r#"{"error":{"code":502,"message":"upstream"}}"#));
        // OpenRouter names a stable class in each API format, and the class proves what the number cannot.
        assert_eq!(
            RateLimited,
            event(
                r#"{"error":{"code":429,"message":"Rate limit exceeded","metadata":{"error_type":"rate_limit_exceeded"}},"choices":[]}"#
            )
        );
        assert_eq!(
            ContextOverflow,
            event(
                r#"{"type":"error","error":{"type":"invalid_request_error","error_type":"context_length_exceeded","message":"too long"}}"#
            )
        );
        for bytes in [
            r#"{"type":"response.failed","response":{"error":{"code":"server_error","message":"busy"}}}"#,
            r#"{"type":"response.failed","response":{"error_type":"provider_overloaded","error":{"code":"unknown","message":"busy"}}}"#,
        ] {
            assert_eq!(ServerError, event(bytes));
        }
        assert_eq!(
            QuotaExhausted,
            event(r#"{"type":"response.failed","response":{"error_type":"payment_required"}}"#)
        );
        // Anthropic names a billing failure and a timeout by type.
        assert_eq!(
            QuotaExhausted,
            event(r#"{"type":"error","error":{"type":"billing_error","message":"billing"}}"#)
        );
        assert_eq!(
            Timeout,
            event(r#"{"type":"error","error":{"type":"timeout_error","message":"slow"}}"#)
        );
        // A code the table does not name, and an event with no fields, stay a generic failure.
        assert_eq!(
            ProviderFailed,
            event(r#"{"type":"response.failed","response":{"error":{"code":"bio_policy","message":"refused"}}}"#)
        );
        assert_eq!(ProviderFailed, event(r#"{"type":"response.failed"}"#));
    }

    // Anthropic answers an input over the context window with a general request error and this message.
    #[test]
    fn anthropic_prompt_too_long_is_context_overflow() {
        let too_long = br#"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 208310 tokens > 200000 maximum"}}"#;
        let other =
            br#"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: must be positive"}}"#;

        assert_eq!(status_kind(400, Some(too_long)), ProviderKind::ContextOverflow);
        assert_ne!(status_kind(400, Some(other)), ProviderKind::ContextOverflow);
    }

    #[test]
    fn status_kind_uses_body_to_split_429_causes() {
        use ProviderKind::*;
        let kind = |status, body: &str| status_kind(status, Some(body.as_bytes()));
        assert_eq!(AuthFailed, status_kind(401, None));
        assert_eq!(PermissionDenied, kind(403, "forbidden"));
        assert_eq!(Conflict, kind(409, "conflict"));
        assert_eq!(BadStatus, kind(418, "a teapot"));
        assert_eq!(ServerError, kind(529, "not json"));
        assert_eq!(Timeout, status_kind(504, None));
        assert_eq!(RateLimitUnknown, kind(429, ""));
        assert_eq!(RateLimited, kind(429, r#"{"error":{"code":"rate_limit_exceeded"}}"#));
        assert_eq!(QuotaExhausted, kind(429, r#"{"error":{"code":"insufficient_quota"}}"#));
        assert_eq!(
            QuotaExhausted,
            kind(
                429,
                r#"{"type":"error","error":{"type":"rate_limit_error","details":{"error_code":"enforced_spend_limit_reached"}}}"#
            )
        );
        // A 429 body that proves a server error is still no rate limit.
        assert_eq!(RateLimitUnknown, kind(429, r#"{"error":{"type":"overloaded_error"}}"#));
        assert_eq!(
            ContextOverflow,
            kind(
                400,
                r#"{"error":{"message":"too long","type":"invalid_request_error","code":"context_length_exceeded"}}"#
            )
        );
        assert_eq!(
            BadStatus,
            kind(400, r#"{"error":{"type":"invalid_request_error","message":"bad"}}"#)
        );
        // A body never overrides a status class other than a plain 4xx.
        assert_eq!(
            ServerError,
            kind(500, r#"{"error":{"code":"context_length_exceeded"}}"#)
        );
        // A spent limit wins over any status: opencode Zen answers spent credit with 401 and its rate limit with a
        // class name no table knows, and the Codex backend names a plan limit in `type`.
        assert_eq!(
            QuotaExhausted,
            kind(
                401,
                r#"{"type":"error","error":{"type":"CreditsError","message":"No credits"}}"#
            )
        );
        assert_eq!(
            RateLimitUnknown,
            kind(
                429,
                r#"{"type":"error","error":{"type":"RateLimitError","message":"Rate limit exceeded"},"metadata":{}}"#
            )
        );
        assert_eq!(
            QuotaExhausted,
            kind(
                429,
                r#"{"error":{"type":"usage_limit_reached","plan_type":"plus","resets_at":1790000000}}"#
            )
        );
    }

    #[test]
    fn detail_text_reads_every_dialect_or_falls_back_to_raw() {
        assert_eq!(
            detail_text(br#"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens is too large"},"request_id":"req_1"}"#).as_deref(),
            Some("invalid_request_error: max_tokens is too large")
        );
        assert_eq!(
            detail_text(br#"{"error":{"message":"too long","type":"invalid_request_error","param":null,"code":"context_length_exceeded"}}"#).as_deref(),
            Some("invalid_request_error: too long (context_length_exceeded)")
        );
        assert_eq!(detail_text(br#"{"error":"boom"}"#).as_deref(), Some("boom"));
        assert_eq!(
            detail_text(b"  <html>\n502 Bad\tGateway\n</html>\r\n").as_deref(),
            Some("<html> 502 Bad Gateway </html>")
        );
        assert_eq!(
            detail_text(br#"{"error":{"code":42}}"#).as_deref(),
            Some(r#"{"error":{"code":42}}"#)
        );
        assert_eq!(detail_text(b" \n "), None);
        // The stream shapes: `response.failed`, a flat `error` event, and a gateway chunk with a numeric code.
        assert_eq!(
            detail_text(br#"{"type":"response.failed","response":{"error":{"code":"rate_limit_exceeded","message":"try again"}}}"#).as_deref(),
            Some("try again (rate_limit_exceeded)")
        );
        assert_eq!(
            detail_text(br#"{"type":"error","code":"insufficient_quota","message":"no credit"}"#).as_deref(),
            Some("no credit (insufficient_quota)")
        );
        assert_eq!(
            detail_text(br#"{"error":{"code":429,"message":"Rate limit exceeded"}}"#).as_deref(),
            Some("Rate limit exceeded (429)")
        );
    }

    #[test]
    fn detail_text_keeps_the_whole_body_and_replaces_unprintable_bytes() {
        let long = format!("a{}", "é".repeat(3_000));
        assert_eq!(detail_text(long.as_bytes()), Some(long));
        assert_eq!(detail_text(b"a\xffb").as_deref(), Some("a?b"));
        assert_eq!(detail_text(b"a\x1bb").as_deref(), Some("a b"));
        assert_eq!(detail_text(b"a\xc2\x85b").as_deref(), Some("a b"));
        assert_eq!(detail_text(b"a\xc2\xc3\xa9").as_deref(), Some("a?é"));
        // A lead byte at the end has no second byte to read.
        assert_eq!(detail_text(b"a\xc2").as_deref(), Some("a?"));
        assert_eq!(detail_text(b"\x1b\x00"), None);
    }
}
