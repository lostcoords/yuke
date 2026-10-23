//! The provider rules over [`yuke_http::Client`]. [`Transport`] streams one SSE response. [`Exchange`] reads one whole
//! small answer. The client follows no redirect, so a key never reaches another origin.

use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::{SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use yuke_http::http::header::{ACCEPT, ACCEPT_ENCODING, CONTENT_ENCODING, CONTENT_TYPE, HeaderName, MaxSizeReached};
use yuke_http::http::{HeaderMap, HeaderValue, Method};
use yuke_http::{Client, Error};

use crate::transport::{
    Answer, Body, BoxBody, BoxFuture, Exchange, ExchangeRequest, Fault, Head, Header, Outgoing, Transport, next_chunk,
};

impl Transport for Client {
    fn open<'a>(
        &'a self,
        request: &'a Outgoing<'_>,
        deadline: Option<std::time::Instant>,
    ) -> BoxFuture<'a, Result<(Head, BoxBody), Fault>> {
        // The client sends a body that owns its bytes, so the parts join here once.
        let mut body = Vec::with_capacity(request.body_len());
        for part in request.body() {
            body.extend_from_slice(part);
        }
        let plan = Plan {
            url: request.url(),
            headers: request.headers(),
            content_type: "application/json",
            // The provider sends SSE, so request it.
            accept: "text/event-stream",
            body,
        };
        Box::pin(round_trip(self, plan, deadline))
    }
}

impl Exchange for Client {
    fn exchange<'a>(
        &'a self,
        request: &'a ExchangeRequest<'_>,
        deadline: Option<std::time::Instant>,
    ) -> BoxFuture<'a, Result<Answer, Fault>> {
        let plan = Plan {
            url: request.url,
            headers: &[],
            content_type: request.content_type,
            accept: "application/json",
            body: request.body.to_vec(),
        };
        Box::pin(async move {
            let (head, mut body) = round_trip(self, plan, deadline).await?;
            let mut bytes = Vec::new();
            while let Some(chunk) = next_chunk(&mut body).await {
                let chunk = chunk?;
                if bytes.len() + chunk.len() > request.max_answer {
                    return Err(Fault::AnswerTooLarge);
                }
                bytes.extend_from_slice(&chunk);
            }
            Ok(Answer { head, body: bytes })
        })
    }
}

/// One request before its head: the caller parts and the media types of the body and of the answer.
struct Plan<'a> {
    url: &'a str,
    headers: &'a [Header],
    content_type: &'static str,
    accept: &'static str,
    body: Vec<u8>,
}

/// Send `plan` with the provider rules, and read the head. The body streams.
async fn round_trip(
    client: &Client,
    plan: Plan<'_>,
    deadline: Option<std::time::Instant>,
) -> Result<(Head, BoxBody), Fault> {
    let mut request = yuke_http::Request::new(Method::POST, plan.url);
    request.headers = headers(&plan)?;
    request.body = Bytes::from(plan.body);
    let response = client.send(request, deadline).await.map_err(fault_of)?;
    let status = response.status.as_u16();
    // The client never follows a redirect, so the key never reaches another origin. A 304 has no redirect target.
    if (300..400).contains(&status) && status != 304 {
        return Err(Fault::RedirectRefused);
    }
    check_content_encoding(&response.headers)?;
    let head = read_head(&response.headers, status, wall_clock_seconds());
    Ok((head, Box::pin(ProviderBody(response.body))))
}

/// The headers of `plan`: the type, the accept, no compression, then the caller headers in order.
fn headers(plan: &Plan<'_>) -> Result<HeaderMap, Fault> {
    // A `HeaderMap` has a size limit, so too many headers fail the request before it leaves.
    let full = |result: Result<(), MaxSizeReached>| result.map_err(|_| Fault::InvalidRequest);
    let mut headers = HeaderMap::new();
    // A caller gives the type of an exchange, so a bad value fails the request instead of a panic.
    let content_type = HeaderValue::from_str(plan.content_type).map_err(|_| Fault::InvalidRequest)?;
    full(headers.try_insert(CONTENT_TYPE, content_type).map(drop))?;
    full(
        headers
            .try_insert(ACCEPT, HeaderValue::from_static(plan.accept))
            .map(drop),
    )?;
    // Without this field, RFC 9110 lets the server choose any compression. The SSE parser reads plain bytes only.
    full(
        headers
            .try_insert(ACCEPT_ENCODING, HeaderValue::from_static("identity"))
            .map(drop),
    )?;
    for header in plan.headers {
        let name = HeaderName::from_bytes(header.name.as_bytes()).map_err(|_| Fault::InvalidRequest)?;
        // Any byte but a control byte is valid, as `route::valid_header_value` checks.
        let value = HeaderValue::from_bytes(header.value.as_bytes()).map_err(|_| Fault::InvalidRequest)?;
        full(headers.try_append(name, value).map(drop))?;
    }
    Ok(headers)
}

/// The request asks for `identity`, so a body in any other `content-encoding` is a malformed response.
fn check_content_encoding(headers: &HeaderMap) -> Result<(), Fault> {
    let identity = |value: &HeaderValue| value.as_bytes().trim_ascii().eq_ignore_ascii_case(b"identity");
    if headers.get_all(CONTENT_ENCODING).iter().all(identity) {
        Ok(())
    } else {
        Err(Fault::MalformedResponse)
    }
}

/// The fault of a client error. Each error has the fault of the same name.
fn fault_of(error: Error) -> Fault {
    match error {
        Error::InvalidRequest => Fault::InvalidRequest,
        Error::BadUrl => Fault::BadUrl,
        Error::DnsFailed => Fault::DnsFailed,
        Error::ConnectFailed => Fault::ConnectFailed,
        Error::ConnectTimeout => Fault::ConnectTimeout,
        Error::CertificateRejected => Fault::CertificateRejected,
        Error::TlsSetupFailed => Fault::TlsSetupFailed,
        Error::IdleTimeout => Fault::IdleTimeout,
        Error::RequestTimeout => Fault::RequestTimeout,
        Error::ConnectionLost => Fault::ConnectionLost,
        Error::MalformedResponse => Fault::MalformedResponse,
    }
}

/// The body of a provider response.
struct ProviderBody(yuke_http::Body);

impl Body for ProviderBody {
    fn poll_chunk(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Result<Bytes, Fault>>> {
        self.get_mut()
            .0
            .poll_chunk(cx)
            .map(|chunk| chunk.map(|chunk| chunk.map_err(fault_of)))
    }
}

fn wall_clock_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| i64::try_from(since.as_secs()).unwrap_or(i64::MAX))
}

/// Read the status, the retry hints, and the request id. `now` is the wall-clock time in seconds since the epoch,
/// for an HTTP-date retry hint.
fn read_head(headers: &HeaderMap, status: u16, now: i64) -> Head {
    let mut head = Head::new(status);
    for (name, value) in headers {
        let value = value.as_bytes();
        let text = std::str::from_utf8(value).ok();
        match name.as_str() {
            "request-id" | "x-request-id" => {
                if head.request_id.is_none() {
                    head.request_id = Some(String::from_utf8_lossy(value).into_owned());
                }
            }
            // The millisecond form wins. Both SDK families read it first.
            "retry-after-ms" => {
                if let Some(ms) = text.and_then(|text| decimal_ms(text, 1.0)) {
                    head.retry_after_ms = Some(ms);
                }
            }
            "retry-after" => {
                if head.retry_after_ms.is_none() {
                    head.retry_after_ms = text.and_then(|text| retry_after_ms(text, now));
                }
            }
            "x-should-retry" => {
                if value.eq_ignore_ascii_case(b"true") {
                    head.should_retry = Some(true);
                }
                if value.eq_ignore_ascii_case(b"false") {
                    head.should_retry = Some(false);
                }
            }
            _ => {}
        }
    }
    head
}

fn retry_after_ms(value: &str, now: i64) -> Option<u64> {
    if let Some(ms) = decimal_ms(value, 1000.0) {
        return Some(ms);
    }
    let at = imf_fixdate(value)?;
    if at <= now {
        return Some(0);
    }
    Some(u64::try_from(at - now).ok()?.saturating_mul(1000))
}

fn decimal_ms(value: &str, ms_per_unit: f64) -> Option<u64> {
    let units: f64 = value.parse().ok()?;
    if !units.is_finite() || units < 0.0 {
        return None;
    }
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "a float cast saturates, so a huge delay becomes `u64::MAX`"
    )]
    let ms = (units * ms_per_unit).ceil() as u64;
    Some(ms)
}

fn imf_fixdate(value: &str) -> Option<i64> {
    const DAYS: [&[u8]; 7] = [b"Mon", b"Tue", b"Wed", b"Thu", b"Fri", b"Sat", b"Sun"];
    const MONTHS: [&[u8]; 12] = [
        b"Jan", b"Feb", b"Mar", b"Apr", b"May", b"Jun", b"Jul", b"Aug", b"Sep", b"Oct", b"Nov", b"Dec",
    ];
    let bytes = value.as_bytes();
    if bytes.len() != 29 || &bytes[3..5] != b", " || &bytes[25..] != b" GMT" {
        return None;
    }
    if [7, 11, 16].iter().any(|&i| bytes[i] != b' ') || bytes[19] != b':' || bytes[22] != b':' {
        return None;
    }
    if !DAYS.contains(&&bytes[0..3]) {
        return None;
    }
    let month = u8::try_from(MONTHS.iter().position(|name| *name == &bytes[8..11])? + 1).ok()?;
    let number = |range: std::ops::Range<usize>| value.get(range)?.parse::<u16>().ok();
    let day = number(5..7)?;
    let year = number(12..16)?;
    let hour = number(17..19)?;
    let minute = number(20..22)?;
    let second = number(23..25)?;
    if day == 0 || day > days_in_month(year, month) || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    Some(
        days_from_civil(year, month, day) * 86_400
            + i64::from(hour) * 3600
            + i64::from(minute) * 60
            + i64::from(second),
    )
}

fn days_in_month(year: u16, month: u8) -> u16 {
    let leap = year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400));
    match month {
        2 if leap => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

fn days_from_civil(year: u16, month: u8, day: u16) -> i64 {
    let y = i64::from(year) - i64::from(month <= 2);
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let m = i64::from(month);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2).div_euclid(5) + i64::from(day) - 1;
    let doe = yoe * 365 + yoe.div_euclid(4) - yoe.div_euclid(100) + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests;
