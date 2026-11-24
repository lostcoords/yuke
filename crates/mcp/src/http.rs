//! The Streamable HTTP client of rmcp over the `yuke-http` client of the app.

use std::collections::HashMap;
use std::sync::Arc;

use futures_util::StreamExt as _;
use futures_util::stream::{BoxStream, unfold};
use rmcp::model::{ClientJsonRpcMessage, ServerJsonRpcMessage};
use rmcp::transport::streamable_http_client::{
    SseError, StreamableHttpClient, StreamableHttpError, StreamableHttpPostResponse, StreamableHttpResponseLimits,
};
use sse_stream::{Sse, SseStream};
use yuke_http::http::header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE};
use yuke_http::http::{HeaderName, HeaderValue, Method, StatusCode};
use yuke_http::{Body, Client, Error, Request, Response};

use crate::oauth::Auth;

const SESSION_ID: HeaderName = HeaderName::from_static("mcp-session-id");

type Failure = StreamableHttpError<Error>;

/// The client of one remote server. A clone shares the client of the app, with its connections, and the login of the
/// server.
#[derive(Clone)]
pub(crate) struct HttpClient {
    pub(crate) client: Arc<Client>,
    /// `None` for a server whose headers hold the `authorization` of their own.
    pub(crate) auth: Option<Arc<Auth>>,
}

impl HttpClient {
    /// Send a request to `uri` with the headers of the config, then the headers that the protocol owns, so a header of
    /// the config cannot replace `accept`, `content-type`, or the session. A request has no time bound, because a tool
    /// call can take long.
    ///
    /// With a login, the request carries its token. A `401` answer to a request with a token refreshes the token once
    /// and sends the request again. A `401` answer that leads to OAuth metadata marks the server as one that needs a
    /// login.
    async fn send(
        &self,
        method: Method,
        uri: &str,
        session_id: Option<&str>,
        headers: HashMap<HeaderName, HeaderValue>,
        body: Option<Vec<u8>>,
    ) -> Result<Response, Failure> {
        let mut request = Request::new(method, uri);
        request.headers.extend(headers);
        request
            .headers
            .insert(ACCEPT, HeaderValue::from_static("application/json, text/event-stream"));
        if let Some(id) = session_id.and_then(|id| HeaderValue::from_str(id).ok()) {
            request.headers.insert(SESSION_ID, id);
        }
        if let Some(body) = body {
            request
                .headers
                .insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
            request.body = vec![body.into()];
        }
        let Some(auth) = &self.auth else {
            return self.client.send(request).await.map_err(StreamableHttpError::Client);
        };
        let token = auth.token().await.map_err(refused)?;
        if let Some(token) = &token {
            bearer(&mut request, token);
        }
        let response = self
            .client
            .send(request.clone())
            .await
            .map_err(StreamableHttpError::Client)?;
        if response.status != StatusCode::UNAUTHORIZED {
            return Ok(response);
        }
        let refreshed = match token {
            Some(rejected) => auth.refresh(Some(&rejected)).await.map_err(refused)?,
            None => None,
        };
        let Some(token) = refreshed else {
            auth.challenged(&response.headers).await;
            return Ok(response);
        };
        bearer(&mut request, &token);
        self.client.send(request).await.map_err(StreamableHttpError::Client)
    }
}

/// Set the token of the login in `request`.
fn bearer(request: &mut Request, token: &str) {
    if let Ok(value) = HeaderValue::try_from(format!("Bearer {token}")) {
        request.headers.insert(AUTHORIZATION, value);
    }
}

/// The failure of a request that the login of the server stopped.
fn refused(text: String) -> Failure {
    StreamableHttpError::UnexpectedServerResponse(text.into())
}

/// Read `body` until it ends or holds more than `limit` bytes.
async fn read(mut body: Body, limit: usize) -> Result<Vec<u8>, Failure> {
    let mut bytes = Vec::new();
    while bytes.len() <= limit
        && let Some(chunk) = body.chunk().await
    {
        bytes.extend_from_slice(&chunk.map_err(StreamableHttpError::Client)?);
    }
    Ok(bytes)
}

/// Whether the content type `value` names the media type `expected`. The parameters and the case do not matter.
fn media_type_is(value: &str, expected: &str) -> bool {
    let (essence, _) = value.split_once(';').unwrap_or((value, ""));
    essence.trim().eq_ignore_ascii_case(expected)
}

impl StreamableHttpClient for HttpClient {
    type Error = Error;

    async fn post_message(
        &self,
        uri: Arc<str>,
        message: ClientJsonRpcMessage,
        session_id: Option<Arc<str>>,
        auth_header: Option<String>,
        custom_headers: HashMap<HeaderName, HeaderValue>,
    ) -> Result<StreamableHttpPostResponse, Failure> {
        let limits = StreamableHttpResponseLimits::default();
        self.post_message_with_response_limits(uri, message, session_id, auth_header, custom_headers, limits)
            .await
    }

    async fn post_message_with_response_limits(
        &self,
        uri: Arc<str>,
        message: ClientJsonRpcMessage,
        session_id: Option<Arc<str>>,
        _auth_header: Option<String>,
        custom_headers: HashMap<HeaderName, HeaderValue>,
        limits: StreamableHttpResponseLimits,
    ) -> Result<StreamableHttpPostResponse, Failure> {
        let body = serde_json::to_vec(&message)?;
        let response = self
            .send(Method::POST, &uri, session_id.as_deref(), custom_headers, Some(body))
            .await?;
        let Response { status, headers, body } = response;
        // A server that dropped the session answers 404, and the worker then starts a new session.
        if status == StatusCode::NOT_FOUND && session_id.is_some() {
            return Err(StreamableHttpError::SessionExpired);
        }
        if !status.is_success() {
            let limit = limits.max_error_response_size;
            let text = read(body, limit).await?;
            let text = String::from_utf8_lossy(&text[..text.len().min(limit)]);
            return Err(StreamableHttpError::UnexpectedServerResponse(
                format!("HTTP {status}: {text}").into(),
            ));
        }
        // Only a request waits for an answer. A server answers a notification with 202, 204, or 200.
        if !matches!(message, ClientJsonRpcMessage::Request(_)) {
            return Ok(StreamableHttpPostResponse::Accepted);
        }
        let session = headers
            .get(SESSION_ID)
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        let content_type = headers.get(CONTENT_TYPE).and_then(|value| value.to_str().ok());
        match content_type {
            Some(kind) if media_type_is(kind, "text/event-stream") => {
                let chunks = unfold(body, |mut body| async { Some((body.chunk().await?, body)) });
                Ok(StreamableHttpPostResponse::Sse(
                    SseStream::from_bytes_stream(chunks).boxed(),
                    session,
                ))
            }
            Some(kind) if media_type_is(kind, "application/json") => {
                let limit = limits.max_json_response_size;
                let bytes = read(body, limit).await?;
                if bytes.len() > limit {
                    return Err(StreamableHttpError::ResponseBodyTooLarge { max_size: limit });
                }
                let message: ServerJsonRpcMessage = serde_json::from_slice(&bytes)?;
                Ok(StreamableHttpPostResponse::Json(message, session))
            }
            other => Err(StreamableHttpError::UnexpectedContentType(other.map(str::to_owned))),
        }
    }

    /// The end of a session. The worker only logs a failure, so the status of the answer does not matter.
    async fn delete_session(
        &self,
        uri: Arc<str>,
        session_id: Arc<str>,
        _auth_header: Option<String>,
        custom_headers: HashMap<HeaderName, HeaderValue>,
    ) -> Result<(), Failure> {
        self.send(Method::DELETE, &uri, Some(&session_id), custom_headers, None)
            .await?;
        Ok(())
    }

    /// The client opens no stream of its own. It declares no capability, so a server has no request to send. A POST
    /// gets its answer on its own stream.
    fn get_stream(
        &self,
        _uri: Arc<str>,
        _session_id: Option<Arc<str>>,
        _last_event_id: Option<String>,
        _auth_header: Option<String>,
        _custom_headers: HashMap<HeaderName, HeaderValue>,
    ) -> impl Future<Output = Result<BoxStream<'static, Result<Sse, SseError>>, Failure>> + Send + '_ {
        std::future::ready(Err(StreamableHttpError::ServerDoesNotSupportSse))
    }
}

#[cfg(test)]
mod tests {
    use super::media_type_is;

    #[test]
    fn a_media_type_matches_without_its_parameters_and_its_case_but_not_a_longer_name() {
        assert!(media_type_is("Application/JSON; charset=utf-8", "application/json"));
        assert!(media_type_is("text/event-stream", "text/event-stream"));
        assert!(!media_type_is("application/jsonx", "application/json"));
        assert!(!media_type_is("application/json-patch+json", "application/json"));
    }
}
