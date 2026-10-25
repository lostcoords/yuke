//! The HTTP functions of the native module for `fetch`, on the [`yuke_http::Client`] of the consumer. `httpSend` sends
//! one request and gives the head with an `HttpBody`. `httpRead` reads one chunk of a body, and `httpClose` closes it.
//! A failure rejects with a record `{ code, message }`, and a stop with `{ cancelled: true }`. Header names and values
//! cross as JavaScript strings with one character for each byte, as a Web IDL `ByteString` holds them.

use std::cell::{Cell, RefCell};
use std::sync::Arc;

use rquickjs::class::Trace;
use rquickjs::convert::List;
use rquickjs::{Class, Ctx, Function, IntoJs, JsLifetime, Object, TypedArray};
use yuke_http::http::{HeaderMap, HeaderName, HeaderValue, Method};

use super::Operation;

/// The body of a response. When QuickJS frees the object, the body drops and closes the connection.
#[derive(Trace, JsLifetime)]
#[rquickjs::class(rename = "HttpBody")]
pub(crate) struct HttpBody {
    /// `None` while a read holds the body, and after the end or a close.
    #[qjs(skip_trace)]
    body: RefCell<Option<yuke_http::Body>>,
    /// A close came, so a read that ends drops the body.
    #[qjs(skip_trace)]
    closed: Cell<bool>,
}

/// Add `httpSend`, `httpRead`, and `httpClose` to `object`, the export object of the native module.
pub(super) fn add<'js>(ctx: &Ctx<'js>, object: &Object<'js>, client: &Arc<yuke_http::Client>) -> rquickjs::Result<()> {
    let client = Arc::clone(client);
    object.set(
        "httpSend",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>,
                  method: String,
                  url: String,
                  headers: Vec<List<(String, String)>>,
                  body: TypedArray<'js, u8>| {
                let request = request(&method, url, &headers, &body);
                let client = Arc::clone(&client);
                Operation::start(&ctx, move |ctx, stop| async move {
                    let request = match request {
                        Ok(request) => request,
                        Err(failure) => return Err(failure.throw(&ctx)),
                    };
                    let sent = tokio::select! {
                        sent = client.send(request, None) => sent,
                        () = stop.cancelled() => return Err(Failure::Cancelled.throw(&ctx)),
                    };
                    let response = sent.map_err(|error| Failure::Http(error).throw(&ctx))?;
                    let head = Head {
                        status: response.status.as_u16(),
                        status_text: response.status.canonical_reason().unwrap_or_default().to_owned(),
                        headers: response
                            .headers
                            .iter()
                            .map(|(name, value)| List((name.as_str().to_owned(), latin1(value.as_bytes()))))
                            .collect(),
                        body: Class::instance(
                            ctx.clone(),
                            HttpBody {
                                body: RefCell::new(Some(response.body)),
                                closed: Cell::new(false),
                            },
                        )?,
                    };
                    Ok(head)
                })
            },
        )?,
    )?;
    object.set(
        "httpRead",
        Function::new(ctx.clone(), |ctx: Ctx<'js>, body: Class<'js, HttpBody>| {
            Operation::start(&ctx, move |ctx, stop| async move {
                // The read holds the body across the wait, so no borrow of the class lives across it.
                let taken = body.borrow().body.borrow_mut().take();
                let Some(mut inner) = taken else {
                    return Ok(None);
                };
                let chunk = tokio::select! {
                    chunk = inner.chunk() => chunk,
                    () = stop.cancelled() => return Err(Failure::Cancelled.throw(&ctx)),
                };
                match chunk {
                    Some(Ok(bytes)) => {
                        let state = body.borrow();
                        if !state.closed.get() {
                            state.body.replace(Some(inner));
                        }
                        Ok(Some(TypedArray::<u8>::new(ctx.clone(), bytes.as_ref())?))
                    }
                    Some(Err(error)) => Err(Failure::Http(error).throw(&ctx)),
                    None => Ok(None),
                }
            })
        })?,
    )?;
    object.set(
        "httpClose",
        Function::new(ctx.clone(), |body: Class<'js, HttpBody>| {
            let state = body.borrow();
            state.closed.set(true);
            drop(state.body.borrow_mut().take());
        })?,
    )?;
    Ok(())
}

/// The head of a response, and its body.
#[derive(IntoJs)]
struct Head<'js> {
    status: u16,
    #[qjs(rename = "statusText")]
    status_text: String,
    headers: Vec<List<(String, String)>>,
    body: Class<'js, HttpBody>,
}

/// The request of the arguments of `httpSend`. A method or a header that HTTP does not allow fails.
fn request(
    method: &str,
    url: String,
    headers: &[List<(String, String)>],
    body: &TypedArray<'_, u8>,
) -> Result<yuke_http::Request, Failure> {
    let invalid = || Failure::Http(yuke_http::Error::InvalidRequest);
    let mut request = yuke_http::Request::new(Method::from_bytes(method.as_bytes()).map_err(|_| invalid())?, url);
    let mut map = HeaderMap::new();
    for List((name, value)) in headers {
        let name = HeaderName::from_bytes(name.as_bytes()).map_err(|_| invalid())?;
        let value = HeaderValue::from_bytes(&bytes_of(value).ok_or_else(invalid)?).map_err(|_| invalid())?;
        map.append(name, value);
    }
    request.headers = map;
    request.body = crate::bytes::copy(body).map_err(|_| invalid())?.into();
    Ok(request)
}

/// The bytes of `text`, which holds one character for each byte. A character above U+00FF gives `None`.
fn bytes_of(text: &str) -> Option<Vec<u8>> {
    text.chars().map(|character| u8::try_from(character).ok()).collect()
}

/// The string of `bytes` with one character for each byte.
fn latin1(bytes: &[u8]) -> String {
    bytes.iter().copied().map(char::from).collect()
}

/// Why a request or a read failed.
enum Failure {
    Http(yuke_http::Error),
    Cancelled,
}

impl Failure {
    /// Throw the record that the promise rejects with.
    fn throw(self, ctx: &Ctx<'_>) -> rquickjs::Error {
        let record = match self {
            Failure::Http(error) => HttpError {
                code: code(error),
                message: error.to_string(),
            }
            .into_js(ctx),
            Failure::Cancelled => Stopped { cancelled: true }.into_js(ctx),
        };
        match record {
            Ok(value) => ctx.throw(value),
            Err(error) => error,
        }
    }
}

/// The record of a failed request or read.
#[derive(IntoJs)]
struct HttpError {
    code: &'static str,
    message: String,
}

/// The record of a stopped request or read.
#[derive(IntoJs)]
struct Stopped {
    cancelled: bool,
}

/// The stable code of `error`, for the `cause` of the `TypeError` of `fetch`.
fn code(error: yuke_http::Error) -> &'static str {
    match error {
        yuke_http::Error::InvalidRequest => "invalid_request",
        yuke_http::Error::BadUrl => "bad_url",
        yuke_http::Error::DnsFailed => "dns_failed",
        yuke_http::Error::ConnectFailed => "connect_failed",
        yuke_http::Error::ConnectTimeout => "connect_timeout",
        yuke_http::Error::CertificateRejected => "certificate_rejected",
        yuke_http::Error::TlsSetupFailed => "tls_setup_failed",
        yuke_http::Error::IdleTimeout => "idle_timeout",
        yuke_http::Error::RequestTimeout => "request_timeout",
        yuke_http::Error::ConnectionLost => "connection_lost",
        yuke_http::Error::MalformedResponse => "malformed_response",
    }
}

#[cfg(test)]
mod tests {
    use super::{bytes_of, latin1};

    #[test]
    fn a_byte_string_crosses_with_one_character_for_each_byte() {
        let bytes = [0x61, 0xe9, 0xff];
        assert_eq!(latin1(&bytes), "aéÿ");
        assert_eq!(bytes_of(&latin1(&bytes)), Some(bytes.to_vec()));
        assert_eq!(bytes_of("€"), None);
    }
}
