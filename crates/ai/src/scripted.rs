//! A transport that answers with scripted replies, for the tests of yuke and of its plugins. Each reply is the Anthropic
//! SSE of a whole answer. The provider path then runs as with a real provider: the stream, the retries, and the tools.

use std::collections::VecDeque;
use std::fmt::{Display, Write};
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::task::{Context, Poll};
use std::time::Instant;

use bytes::Bytes;
use serde_json::{Value, json};

use crate::transport::{Body, BoxBody, BoxFuture, Fault, Head, Header, Outgoing, Transport};

/// `events` as one SSE body: each event is the data of one message.
pub fn sse<T: Display>(events: &[T]) -> String {
    let mut output = String::new();
    for event in events {
        // A write to a `String` cannot fail.
        if write!(output, "data: {event}\n\n").is_err() {
            unreachable!("a write to a String fails");
        }
    }
    output
}

fn message_start() -> Value {
    json!({"type": "message_start", "message": {"usage": {"input_tokens": 0}}})
}

fn text_start() -> Value {
    json!({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
}

fn text_delta(text: &str) -> Value {
    json!({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}})
}

fn overloaded() -> Value {
    json!({"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}})
}

fn message_end(stop_reason: &str) -> [Value; 2] {
    [
        json!({"type": "message_delta", "delta": {"stop_reason": stop_reason}, "usage": {"output_tokens": 1}}),
        json!({"type": "message_stop"}),
    ]
}

/// One complete answer with the text `text`.
pub fn text_reply(text: &str) -> String {
    let [delta, stop] = message_end("end_turn");
    sse(&[
        message_start(),
        text_start(),
        text_delta(text),
        json!({"type": "content_block_stop", "index": 0}),
        delta,
        stop,
    ])
}

/// `reply`, an answer of this module, with `input_tokens` as the input tokens of its usage.
pub fn counted(reply: &str, input_tokens: u64) -> String {
    reply.replacen(r#""input_tokens":0"#, &format!(r#""input_tokens":{input_tokens}"#), 1)
}

/// An answer that fails with an overload error before any output. The default retry policy retries it.
pub fn overloaded_reply() -> String {
    sse(&[message_start(), overloaded()])
}

/// An answer that streams `text`, then fails with an overload error. The output before the error stops a retry, so the
/// request fails at once.
pub fn failed_reply(text: &str) -> String {
    sse(&[message_start(), text_start(), text_delta(text), overloaded()])
}

/// One complete answer that asks for `calls`. Each call has an id, a name, and JSON arguments.
pub fn tool_reply(calls: &[(&str, &str, &str)]) -> String {
    calls_reply(calls, "tool_use")
}

/// An answer like [`tool_reply`] that the output limit cut.
pub fn cut_reply(calls: &[(&str, &str, &str)]) -> String {
    calls_reply(calls, "max_tokens")
}

fn calls_reply(calls: &[(&str, &str, &str)], stop_reason: &str) -> String {
    let mut events = vec![message_start()];
    for (index, (id, name, arguments)) in calls.iter().enumerate() {
        events.extend([
            json!({
                "type": "content_block_start",
                "index": index,
                "content_block": {"type": "tool_use", "id": id, "name": name, "input": {}},
            }),
            json!({
                "type": "content_block_delta",
                "index": index,
                "delta": {"type": "input_json_delta", "partial_json": arguments},
            }),
            json!({"type": "content_block_stop", "index": index}),
        ]);
    }
    events.extend(message_end(stop_reason));
    sse(&events)
}

/// One request that the transport got.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sent {
    /// The URL of the request.
    pub url: String,
    /// The body of the request, as text.
    pub body: String,
    /// The headers of the request.
    pub headers: Vec<Header>,
}

/// Answers each request with the next scripted reply, and records each request. A clone shares the script and the
/// records. A request after the last reply gets an error answer, and [`ScriptedTransport::check`] reports it.
#[derive(Debug, Clone, Default)]
pub struct ScriptedTransport {
    script: Arc<Mutex<Script>>,
}

#[derive(Debug, Default)]
struct Script {
    replies: VecDeque<Reply>,
    sent: Vec<Sent>,
    /// The number of requests that found no reply.
    unanswered: usize,
}

/// One scripted reply. A reply that stalls never ends after its body.
#[derive(Debug)]
struct Reply {
    body: Bytes,
    stalls: bool,
}

impl ScriptedTransport {
    /// A transport that answers with `replies`, in order.
    pub fn new(replies: impl IntoIterator<Item = String>) -> Self {
        let transport = ScriptedTransport::default();
        for reply in replies {
            transport.push(reply);
        }
        transport
    }

    /// Add `reply` to the end of the script.
    pub fn push(&self, reply: String) {
        self.add(reply, false);
    }

    /// Add a reply that sends `reply`, then waits forever, as a stream that the provider holds open.
    #[must_use]
    pub fn then_stall(self, reply: String) -> Self {
        self.add(reply, true);
        self
    }

    fn add(&self, reply: String, stalls: bool) {
        self.script().replies.push_back(Reply {
            body: Bytes::from(reply),
            stalls,
        });
    }

    fn script(&self) -> MutexGuard<'_, Script> {
        self.script.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The requests, in send order.
    pub fn sent(&self) -> Vec<Sent> {
        self.script().sent.clone()
    }

    /// The request URLs, in send order.
    pub fn urls(&self) -> Vec<String> {
        self.script().sent.iter().map(|sent| sent.url.clone()).collect()
    }

    /// The request bodies, in send order.
    pub fn requests(&self) -> Vec<String> {
        self.script().sent.iter().map(|sent| sent.body.clone()).collect()
    }

    /// The headers of each request, in send order.
    pub fn headers(&self) -> Vec<Vec<Header>> {
        self.script().sent.iter().map(|sent| sent.headers.clone()).collect()
    }

    /// The value of the header `name` in each request, in send order.
    pub fn header(&self, name: &str) -> Vec<Option<String>> {
        self.script()
            .sent
            .iter()
            .map(|sent| {
                sent.headers
                    .iter()
                    .find(|header| header.name == name)
                    .map(|header| header.value.to_string())
            })
            .collect()
    }

    /// Check that each request got a scripted reply, and that each reply went out.
    ///
    /// # Errors
    ///
    /// Returns a text that names the requests without a reply and the replies without a request.
    pub fn check(&self) -> Result<(), String> {
        let script = self.script();
        match (script.unanswered, script.replies.len()) {
            (0, 0) => Ok(()),
            (unanswered, 0) => Err(format!(
                "the model got {unanswered} request(s) after the last scripted reply"
            )),
            (0, unused) => Err(format!("{unused} scripted reply(s) got no request")),
            (unanswered, unused) => Err(format!(
                "the model got {unanswered} request(s) after the last scripted reply, and {unused} reply(s) got no \
                 request"
            )),
        }
    }
}

impl Transport for ScriptedTransport {
    fn open<'a>(
        &'a self,
        request: &'a Outgoing<'_>,
        _: Option<Instant>,
    ) -> BoxFuture<'a, Result<(Head, BoxBody), Fault>> {
        let mut script = self.script();
        script.sent.push(Sent {
            url: request.url().to_owned(),
            body: String::from_utf8_lossy(&request.body().flatten().copied().collect::<Vec<u8>>()).into_owned(),
            headers: request.headers().to_vec(),
        });
        let (head, reply) = if let Some(reply) = script.replies.pop_front() {
            (Head::new(200), reply)
        } else {
            script.unanswered += 1;
            // The invalid-request error is not retryable, so the turn fails at once with this text.
            let message = format!("the scripted model has no reply for request {}", script.sent.len());
            let body = json!({"type": "error", "error": {"type": "invalid_request_error", "message": message}});
            let reply = Reply {
                body: Bytes::from(body.to_string()),
                stalls: false,
            };
            (Head::new(400), reply)
        };
        let body: BoxBody = Box::pin(OneChunk {
            chunk: Some(reply.body),
            stalls: reply.stalls,
        });
        Box::pin(std::future::ready(Ok((head, body))))
    }
}

/// A body of one chunk. A body that stalls never ends after its chunk.
struct OneChunk {
    chunk: Option<Bytes>,
    stalls: bool,
}

impl Body for OneChunk {
    fn poll_chunk(mut self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<Option<Result<Bytes, Fault>>> {
        match self.chunk.take() {
            Some(chunk) => Poll::Ready(Some(Ok(chunk))),
            None if self.stalls => Poll::Pending,
            None => Poll::Ready(None),
        }
    }
}

/// A transport whose answer never ends, like a provider that holds its stream open. The same value is the body of that
/// answer.
#[derive(Debug)]
pub struct Stalled;

impl Transport for Stalled {
    fn open<'a>(&'a self, _: &'a Outgoing<'_>, _: Option<Instant>) -> BoxFuture<'a, Result<(Head, BoxBody), Fault>> {
        let body: BoxBody = Box::pin(Stalled);
        Box::pin(std::future::ready(Ok((Head::new(200), body))))
    }
}

impl Body for Stalled {
    fn poll_chunk(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<Option<Result<Bytes, Fault>>> {
        Poll::Pending
    }
}

#[cfg(test)]
mod tests {
    use std::task::Waker;

    use super::*;
    use crate::request::Protocol;
    use crate::stream::Options;
    use crate::testing::{block_on, generate_with, target};

    #[test]
    fn each_request_gets_the_next_reply_in_order_and_leaves_its_record() {
        let transport = ScriptedTransport::new([text_reply("one"), text_reply("two")]);
        let target = target(Protocol::AnthropicMessages);

        let first = generate_with(&transport, &target, "first question", Options::default()).unwrap();
        let second = generate_with(&transport, &target, "second question", Options::default()).unwrap();

        assert_eq!([first.completion.text(), second.completion.text()], ["one", "two"]);
        let sent = transport.sent();
        assert_eq!(sent.len(), 2);
        assert!(sent[0].body.contains("first question") && sent[1].body.contains("second question"));
        assert_eq!(transport.urls(), [sent[0].url.clone(), sent[1].url.clone()]);
        assert_eq!(transport.check(), Ok(()));
    }

    #[test]
    fn a_request_after_the_last_reply_fails_at_once_and_the_check_names_it() {
        let transport = ScriptedTransport::new([text_reply("one")]);
        let target = target(Protocol::AnthropicMessages);

        generate_with(&transport, &target, "first", Options::default()).unwrap();
        let error = generate_with(&transport, &target, "second", Options::default()).unwrap_err();

        assert!(
            error
                .to_string()
                .contains("the scripted model has no reply for request 2"),
            "{error}"
        );
        assert_eq!(transport.sent().len(), 2);
        assert_eq!(
            transport.check(),
            Err("the model got 1 request(s) after the last scripted reply".to_owned())
        );
        transport.push(text_reply("late"));
        assert_eq!(
            transport.check(),
            Err("the model got 1 request(s) after the last scripted reply, and 1 reply(s) got no request".to_owned())
        );
    }

    #[test]
    fn a_reply_without_a_request_fails_the_check() {
        let transport = ScriptedTransport::new([text_reply("one"), text_reply("two")]);
        let target = target(Protocol::AnthropicMessages);

        generate_with(&transport, &target, "only", Options::default()).unwrap();

        assert_eq!(transport.check(), Err("1 scripted reply(s) got no request".to_owned()));
    }

    #[test]
    fn a_stalled_reply_sends_its_body_and_never_ends() {
        let transport = ScriptedTransport::default().then_stall(text_reply("part"));
        let request = Outgoing::new("https://example.test/v1/messages", &[], b"{}");

        let (head, mut body) = block_on(transport.open(&request, None)).unwrap();
        let mut context = Context::from_waker(Waker::noop());
        let first = body.as_mut().poll_chunk(&mut context);
        let second = body.as_mut().poll_chunk(&mut context);

        assert_eq!(head.status, 200);
        assert!(matches!(first, Poll::Ready(Some(Ok(chunk))) if chunk == text_reply("part").as_bytes()));
        assert!(second.is_pending());
    }
}
