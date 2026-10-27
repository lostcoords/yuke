//! A transport that answers with scripted replies, for the tests of yuke and of its plugins. A reply is an [`Answer`],
//! which the transport writes in the stream format of the protocol of each request, or a body as it is. The functions
//! of this module write the Anthropic SSE of an answer. The provider path then runs as with a real provider: the
//! stream, the retries, and the tools.

use std::collections::VecDeque;
use std::fmt::{Display, Write};
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::task::{Context, Poll};
use std::time::Instant;

use bytes::Bytes;
use serde_json::{Value, json};

use crate::request::Protocol;
use crate::transport::{Body, BoxBody, BoxFuture, Fault, Head, Header, Outgoing, Transport};
use crate::wire::outgoing::protocol_path;

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

/// The start of an answer that streams `text` and has no end, for [`Answer::Stall`].
fn partial_reply(text: &str) -> String {
    sse(&[message_start(), text_start(), text_delta(text)])
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

/// One scripted answer of the model. The transport writes it in the stream format of the protocol of the request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Answer {
    /// A complete answer with a text.
    Text {
        /// The text of the answer.
        text: String,
        /// The input tokens of the usage of the answer.
        input_tokens: u64,
    },
    /// A complete answer that asks for tool calls.
    Calls {
        /// The calls in order.
        calls: Vec<Call>,
        /// The input tokens of the usage of the answer.
        input_tokens: u64,
        /// The output limit cut the answer after the calls.
        cut: bool,
    },
    /// An overload error before any output. The default retry policy retries it.
    Overloaded,
    /// An answer that streams a text, then fails with an overload error. The output before the error stops a retry.
    Failed {
        /// The text before the error.
        text: String,
    },
    /// An answer that streams a text and never ends, as a stream that the provider holds open.
    Stall {
        /// The text before the stall.
        text: String,
    },
}

/// One tool call of an [`Answer`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Call {
    /// The id of the call.
    pub id: String,
    /// The name of the tool.
    pub name: String,
    /// The arguments as JSON text.
    pub arguments: String,
}

impl Answer {
    /// The body of this answer in the stream format of `protocol`, and whether the stream stays open after the body.
    fn encode(&self, protocol: Protocol) -> (String, bool) {
        match protocol {
            Protocol::AnthropicMessages => self.anthropic(),
            Protocol::OpenaiChat => self.chat(),
            Protocol::OpenaiResponses => self.responses(),
        }
    }

    fn anthropic(&self) -> (String, bool) {
        let body = match self {
            Answer::Text { text, input_tokens } => counted(&text_reply(text), *input_tokens),
            Answer::Calls {
                calls,
                input_tokens,
                cut,
            } => {
                let calls: Vec<(&str, &str, &str)> = calls
                    .iter()
                    .map(|call| (call.id.as_str(), call.name.as_str(), call.arguments.as_str()))
                    .collect();
                let stop_reason = if *cut { "max_tokens" } else { "tool_use" };
                counted(&calls_reply(&calls, stop_reason), *input_tokens)
            }
            Answer::Overloaded => overloaded_reply(),
            Answer::Failed { text } => failed_reply(text),
            Answer::Stall { text } => return (partial_reply(text), true),
        };
        (body, false)
    }

    fn chat(&self) -> (String, bool) {
        let chunk = |delta: Value, finish: Option<&str>| {
            json!({"choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}).to_string()
        };
        let end = |finish: &str, input_tokens: u64| {
            [
                chunk(json!({}), Some(finish)),
                json!({"choices": [], "usage": {"prompt_tokens": input_tokens, "completion_tokens": 1}}).to_string(),
                "[DONE]".to_owned(),
            ]
        };
        let overloaded = json!({"error": {"code": "server_error", "message": "Overloaded"}, "choices": []}).to_string();
        let events = match self {
            Answer::Text { text, input_tokens } => {
                let mut events = vec![chunk(json!({"role": "assistant", "content": text}), None)];
                events.extend(end("stop", *input_tokens));
                events
            }
            Answer::Calls {
                calls,
                input_tokens,
                cut,
            } => {
                let mut events: Vec<String> = calls
                    .iter()
                    .enumerate()
                    .map(|(index, call)| {
                        let function = json!({"name": call.name, "arguments": call.arguments});
                        let call = json!({"index": index, "id": call.id, "type": "function", "function": function});
                        chunk(json!({"tool_calls": [call]}), None)
                    })
                    .collect();
                events.extend(end(if *cut { "length" } else { "tool_calls" }, *input_tokens));
                events
            }
            Answer::Overloaded => vec![overloaded],
            Answer::Failed { text } => vec![chunk(json!({"content": text}), None), overloaded],
            Answer::Stall { text } => {
                return (sse(&[chunk(json!({"role": "assistant", "content": text}), None)]), true);
            }
        };
        (sse(&events), false)
    }

    fn responses(&self) -> (String, bool) {
        let created = json!({"type": "response.created"});
        let text_start = [
            json!({"type": "response.output_item.added", "output_index": 0, "item": {"type": "message"}}),
            json!({
                "type": "response.content_part.added",
                "output_index": 0,
                "content_index": 0,
                "part": {"type": "output_text"},
            }),
        ];
        let text_delta = |text: &str| json!({"type": "response.output_text.delta", "output_index": 0, "delta": text});
        let usage = |input_tokens: u64| json!({"input_tokens": input_tokens, "output_tokens": 1});
        let failed = json!({
            "type": "response.failed",
            "response": {"status": "failed", "error": {"code": "server_error", "message": "Overloaded"}},
        });
        let mut events = vec![created];
        match self {
            Answer::Text { text, input_tokens } => {
                events.extend(text_start);
                events.extend([
                    text_delta(text),
                    json!({"type": "response.output_text.done", "output_index": 0}),
                    json!({
                        "type": "response.content_part.done",
                        "output_index": 0,
                        "content_index": 0,
                        "part": {"type": "output_text"},
                    }),
                    json!({"type": "response.output_item.done", "output_index": 0, "item": {"type": "message"}}),
                    json!({
                        "type": "response.completed",
                        "response": {"status": "completed", "usage": usage(*input_tokens)},
                    }),
                ]);
            }
            Answer::Calls {
                calls,
                input_tokens,
                cut,
            } => {
                for (index, call) in calls.iter().enumerate() {
                    events.extend([
                        json!({
                            "type": "response.output_item.added",
                            "output_index": index,
                            "item": {"type": "function_call", "call_id": call.id, "name": call.name},
                        }),
                        json!({
                            "type": "response.function_call_arguments.delta",
                            "output_index": index,
                            "delta": call.arguments,
                        }),
                        json!({
                            "type": "response.output_item.done",
                            "output_index": index,
                            "item": {"type": "function_call", "status": "completed", "arguments": call.arguments},
                        }),
                    ]);
                }
                events.push(if *cut {
                    json!({
                        "type": "response.incomplete",
                        "response": {
                            "status": "incomplete",
                            "incomplete_details": {"reason": "max_output_tokens"},
                            "usage": usage(*input_tokens),
                        },
                    })
                } else {
                    json!({
                        "type": "response.completed",
                        "response": {"status": "completed", "usage": usage(*input_tokens)},
                    })
                });
            }
            Answer::Overloaded => events.push(failed),
            Answer::Failed { text } => {
                events.extend(text_start);
                events.extend([text_delta(text), failed]);
            }
            Answer::Stall { text } => {
                events.extend(text_start);
                events.push(text_delta(text));
                return (sse(&events), true);
            }
        }
        (sse(&events), false)
    }
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

impl Sent {
    /// The protocol of the request, by the path of its URL. A URL of another path has none.
    pub fn protocol(&self) -> Option<Protocol> {
        [
            Protocol::AnthropicMessages,
            Protocol::OpenaiChat,
            Protocol::OpenaiResponses,
        ]
        .into_iter()
        .find(|protocol| self.url.ends_with(protocol_path(*protocol)))
    }
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

/// One scripted reply: a body as it is, or an answer in the stream format of the request.
#[derive(Debug)]
enum Reply {
    /// A body that stalls never ends after its bytes.
    Body {
        body: Bytes,
        stalls: bool,
    },
    Answer(Answer),
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

    /// Add the body `reply` to the end of the script.
    pub fn push(&self, reply: String) {
        self.add(reply, false);
    }

    /// Add `answer` to the end of the script.
    pub fn push_answer(&self, answer: Answer) {
        self.script().replies.push_back(Reply::Answer(answer));
    }

    /// Add a reply that sends `reply`, then waits forever, as a stream that the provider holds open.
    #[must_use]
    pub fn then_stall(self, reply: String) -> Self {
        self.add(reply, true);
        self
    }

    fn add(&self, reply: String, stalls: bool) {
        self.script().replies.push_back(Reply::Body {
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
        let sent = Sent {
            url: request.url().to_owned(),
            body: String::from_utf8_lossy(&request.body().flatten().copied().collect::<Vec<u8>>()).into_owned(),
            headers: request.headers().to_vec(),
        };
        let protocol = sent.protocol();
        script.sent.push(sent);
        // The invalid-request error is not retryable, so the turn fails at once with this text.
        let refuse = |message: String| {
            let body = json!({"type": "error", "error": {"type": "invalid_request_error", "message": message}});
            (Head::new(400), Bytes::from(body.to_string()), false)
        };
        let (head, body, stalls) = match (script.replies.pop_front(), protocol) {
            (Some(Reply::Body { body, stalls }), _) => (Head::new(200), body, stalls),
            (Some(Reply::Answer(answer)), Some(protocol)) => {
                let (body, stalls) = answer.encode(protocol);
                (Head::new(200), Bytes::from(body), stalls)
            }
            (Some(Reply::Answer(_)), None) => {
                refuse(format!("the scripted model has no protocol for {}", request.url()))
            }
            (None, _) => {
                script.unanswered += 1;
                refuse(format!(
                    "the scripted model has no reply for request {}",
                    script.sent.len()
                ))
            }
        };
        let body: BoxBody = Box::pin(OneChunk {
            chunk: Some(body),
            stalls,
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
    use crate::failure::{Failure, ProviderKind};
    use crate::response::{Completion, FinishReason, Partial};
    use crate::stream::Options;
    use crate::stream::testing::Harness;
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

    const PROTOCOLS: [Protocol; 3] = [
        Protocol::AnthropicMessages,
        Protocol::OpenaiChat,
        Protocol::OpenaiResponses,
    ];

    fn call(id: &str, name: &str, arguments: &str) -> Call {
        Call {
            id: id.to_owned(),
            name: name.to_owned(),
            arguments: arguments.to_owned(),
        }
    }

    #[test]
    fn each_answer_reads_the_same_in_each_protocol() {
        for protocol in PROTOCOLS {
            let transport = ScriptedTransport::default();
            for answer in [
                Answer::Text {
                    text: "hi".to_owned(),
                    input_tokens: 7,
                },
                Answer::Calls {
                    calls: vec![call("a", "read", r#"{"path":"x"}"#), call("b", "exec", "{}")],
                    input_tokens: 9,
                    cut: false,
                },
                Answer::Calls {
                    calls: vec![call("c", "read", "{}")],
                    input_tokens: 0,
                    cut: true,
                },
                Answer::Overloaded,
                Answer::Failed {
                    text: "part".to_owned(),
                },
            ] {
                transport.push_answer(answer);
            }
            let target = target(protocol);
            let next = || generate_with(&transport, &target, "go", Options::default());
            let calls = |completion: &Completion| -> Vec<(String, String, String)> {
                completion
                    .tool_calls()
                    .map(|call| (call.call_id.clone(), call.name.clone(), call.arguments.clone()))
                    .collect()
            };

            let text = next().unwrap().completion;
            let asked = next().unwrap().completion;
            let cut = next().unwrap().completion;
            let overloaded = next().unwrap_err();
            let failed = next().unwrap_err();

            let context = format!("{protocol:?}");
            assert_eq!(
                (text.text(), text.finish_reason, text.usage.input),
                ("hi".to_owned(), FinishReason::Stop, Some(7)),
                "{context}"
            );
            assert_eq!(
                (calls(&asked), asked.finish_reason, asked.usage.input),
                (
                    vec![
                        ("a".to_owned(), "read".to_owned(), r#"{"path":"x"}"#.to_owned()),
                        ("b".to_owned(), "exec".to_owned(), "{}".to_owned())
                    ],
                    FinishReason::ToolCalls,
                    Some(9)
                ),
                "{context}"
            );
            assert_eq!(
                (calls(&cut), cut.finish_reason),
                (
                    vec![("c".to_owned(), "read".to_owned(), "{}".to_owned())],
                    FinishReason::Length
                ),
                "{context}"
            );
            assert_eq!(
                (overloaded.cause, overloaded.partial),
                (Failure::Provider(ProviderKind::ServerError), Vec::new()),
                "{context}"
            );
            assert_eq!(
                (failed.cause, failed.partial),
                (
                    Failure::Provider(ProviderKind::ServerError),
                    vec![Partial::Text("part".to_owned())]
                ),
                "{context}"
            );
            assert_eq!(transport.check(), Ok(()), "{context}");
        }
    }

    #[test]
    fn a_stalled_answer_streams_its_text_and_never_ends_in_each_protocol() {
        for protocol in PROTOCOLS {
            let transport = ScriptedTransport::default();
            transport.push_answer(Answer::Stall {
                text: "part".to_owned(),
            });
            let url = format!("https://example.test/v1{}", protocol_path(protocol));
            let request = Outgoing::new(&url, &[], b"{}");

            let (_, mut body) = block_on(transport.open(&request, None)).unwrap();
            let mut context = Context::from_waker(Waker::noop());
            let Poll::Ready(Some(Ok(chunk))) = body.as_mut().poll_chunk(&mut context) else {
                panic!("{protocol:?}: no first chunk");
            };
            let second = body.as_mut().poll_chunk(&mut context);

            let text = std::str::from_utf8(&chunk).unwrap();
            let payloads: Vec<&str> = text
                .split("\n\n")
                .filter_map(|event| event.strip_prefix("data: "))
                .collect();
            let mut harness = Harness::new(protocol);
            harness.feed(&payloads).unwrap();
            harness.expect_trace("start 0 text\ntext_delta 0 \"part\"");
            assert!(second.is_pending(), "{protocol:?}");
        }
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
