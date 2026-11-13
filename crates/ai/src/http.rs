//! The provider rules over [`yuke_http::Client`]. [`Transport`] streams one SSE response. [`Exchange`] reads one whole
//! small answer. The client follows no redirect, so a key never reaches another origin.

use std::pin::Pin;
use std::task::{Context, Poll};

use bytes::Bytes;
use yuke_http::http::header::{ACCEPT, ACCEPT_ENCODING, CONTENT_ENCODING, CONTENT_TYPE, HeaderName, MaxSizeReached};
use yuke_http::http::{HeaderMap, HeaderValue, Method};
use yuke_http::{Client, Error};

use crate::Header;
use crate::transport::{
    Body, BoxBody, BoxFuture, Exchange, ExchangeAnswer, ExchangeRequest, Fault, Head, Outgoing, Transport, next_chunk,
};

impl Transport for Client {
    fn open<'a>(
        &'a self,
        request: &'a Outgoing<'_>,
        deadline: Option<std::time::Instant>,
    ) -> BoxFuture<'a, Result<(Head, BoxBody), Fault>> {
        let plan = Plan {
            url: request.url(),
            headers: request.headers(),
            content_type: "application/json",
            // The provider sends SSE, so request it.
            accept: "text/event-stream",
            body: request.body().to_vec(),
        };
        Box::pin(round_trip(self, plan, deadline))
    }
}

impl Exchange for Client {
    fn exchange<'a>(
        &'a self,
        request: &'a ExchangeRequest<'_>,
        deadline: Option<std::time::Instant>,
    ) -> BoxFuture<'a, Result<ExchangeAnswer, Fault>> {
        let plan = Plan {
            url: request.url,
            headers: &[],
            content_type: request.content_type,
            accept: "application/json",
            body: vec![Bytes::copy_from_slice(request.body)],
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
            Ok(ExchangeAnswer { head, body: bytes })
        })
    }
}

/// One request before its head: the caller parts and the media types of the body and of the answer.
struct Plan<'a> {
    url: &'a str,
    headers: &'a [Header],
    content_type: &'static str,
    accept: &'static str,
    body: Vec<Bytes>,
}

/// Send `plan` with the provider rules, and read the head. The body streams.
async fn round_trip(
    client: &Client,
    plan: Plan<'_>,
    deadline: Option<std::time::Instant>,
) -> Result<(Head, BoxBody), Fault> {
    let mut request = yuke_http::Request::new(Method::POST, plan.url);
    request.headers = headers(&plan)?;
    request.body = plan.body;
    let response = client.send(request, deadline).await.map_err(fault_of)?;
    let status = response.status.as_u16();
    // The client never follows a redirect, so the key never reaches another origin.
    if (300..400).contains(&status) {
        return Err(Fault::RedirectRefused);
    }
    check_content_encoding(&response.headers)?;
    let head = read_head(&response.headers, status);
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

/// Read the status, the retry hints, and the request id. A `retry-after` in the HTTP-date form gives no hint.
fn read_head(headers: &HeaderMap, status: u16) -> Head {
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
                    head.retry_after_ms = text.and_then(|text| decimal_ms(text, 1000.0));
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

#[cfg(test)]
mod tests;
