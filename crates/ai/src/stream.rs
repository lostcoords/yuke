//! A stream opens one attempt, pulls SSE payloads from its body, and answers neutral events one at a time.
//! It owns the response body and every buffer.

mod anthropic;
pub(crate) mod draft;
mod openai_chat;
mod openai_responses;
mod sse;
#[cfg(test)]
pub(crate) mod testing;

use std::time::Instant;

use crate::encoder::Encoded;
use crate::failure::{self, Failure, ProviderKind};
use crate::request::{Origin, Protocol};
use crate::response::{AttemptInfo, Delivery, Event, ResponseLimits};
use crate::transport::{self, BoxBody, Transport};
use draft::{DecodeError, Draft};
use sse::{Sse, Step};

/// The rules of one protocol. A reducer decodes one SSE payload into the events of its draft.
#[derive(Debug)]
enum Reducer {
    Anthropic(anthropic::Reducer),
    Chat(openai_chat::Reducer),
    Responses(openai_responses::Reducer),
}

impl Reducer {
    fn new(protocol: Protocol, draft: Draft) -> Self {
        match protocol {
            Protocol::AnthropicMessages => Reducer::Anthropic(anthropic::Reducer::new(draft)),
            Protocol::OpenaiChat => Reducer::Chat(openai_chat::Reducer::new(draft)),
            Protocol::OpenaiResponses => Reducer::Responses(openai_responses::Reducer::new(draft)),
        }
    }

    /// Decode one payload into the draft events, or return the provider failure it names.
    fn decode(&mut self, data: &str) -> Result<Option<ProviderKind>, DecodeError> {
        self.draft_mut().begin_payload(data);
        match self {
            Reducer::Anthropic(reducer) => reducer.decode(data),
            Reducer::Chat(reducer) => reducer.decode(data),
            Reducer::Responses(reducer) => reducer.decode(data),
        }
    }

    fn draft(&self) -> &Draft {
        match self {
            Reducer::Anthropic(reducer) => &reducer.draft,
            Reducer::Chat(reducer) => &reducer.draft,
            Reducer::Responses(reducer) => &reducer.draft,
        }
    }

    fn draft_mut(&mut self) -> &mut Draft {
        match self {
            Reducer::Anthropic(reducer) => &mut reducer.draft,
            Reducer::Chat(reducer) => &mut reducer.draft,
            Reducer::Responses(reducer) => &mut reducer.draft,
        }
    }
}

/// How to receive one attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Options {
    /// Bounds on what the response can make the library hold.
    pub limits: ResponseLimits,
    /// The end of the whole exchange, and it can span several attempts. Past it, the attempt fails with
    /// [`crate::transport::Fault::RequestTimeout`]. Before the send, it fails with
    /// [`crate::transport::Fault::ConnectTimeout`].
    pub deadline: Option<Instant>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Streaming,
    /// The next call returns this failure, then the stream ends.
    Failed(Failure),
    Ended,
}

/// Every event of one attempt, with no retained output. See the module documentation.
pub struct Stream {
    info: AttemptInfo,
    /// The response body, or `None` when the transport opened none. The stream owns the body until the stream drops,
    /// and the drop closes the connection.
    body: Option<BoxBody>,
    /// The body returned its last chunk.
    body_ended: bool,
    state: State,
    reducer: Reducer,
    parser: Sse,
    /// The current payload, which the pending deltas borrow. Its buffer returns to the parser for the next one.
    payload: String,
    /// `payload` holds the buffer of the parser, which the parser needs back before it reads on.
    payload_lent: bool,
    /// The index of the next unread event of the draft.
    next_event: usize,
}

impl std::fmt::Debug for Stream {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Stream")
            .field("info", &self.info)
            .field("state", &self.state)
            .finish_non_exhaustive()
    }
}

impl Stream {
    /// Open one attempt. Borrow `request` only until this returns. An opening fault, and an answer other than 200,
    /// become the first event.
    pub async fn open(transport: &dyn Transport, request: &Encoded<'_>, options: Options) -> Stream {
        let limits = options.limits;
        // The stream keeps no request bytes, so the reasoning origin is its own copy.
        let draft = Draft::new(Origin::from(request.origin), limits);
        let mut stream = Stream {
            info: AttemptInfo::default(),
            body: None,
            body_ended: false,
            state: State::Streaming,
            reducer: Reducer::new(request.protocol, draft),
            parser: Sse::new(limits.max_response_bytes, limits.max_event_bytes),
            payload: String::new(),
            payload_lent: false,
            next_event: 0,
        };
        let (head, mut body) = match transport.open(&request.http, options.deadline).await {
            Ok(opened) => opened,
            Err(fault) => {
                stream.info.delivery = if fault.sent_nothing() {
                    Delivery::DefinitelyUnsent
                } else {
                    Delivery::PossiblySent
                };
                stream.state = State::Failed(Failure::Transport(fault));
                return stream;
            }
        };
        // The transport read the head, so the provider received the request.
        stream.info.delivery = Delivery::PossiblySent;
        stream.info.status = Some(head.status);
        stream.info.request_id = head.request_id;
        stream.info.retry_after_ms = head.retry_after_ms;
        stream.info.should_retry = head.should_retry;
        if head.status != 200 {
            stream.info.error_body = read_error_body(&mut body, limits.max_error_body_bytes).await;
            let kind = failure::status_kind(head.status, stream.info.error_body.as_deref());
            stream.state = State::Failed(Failure::Provider(kind));
        }
        stream.body = Some(body);
        stream
    }

    /// The attempt facts, on success and failure.
    pub fn info(&self) -> &AttemptInfo {
        &self.info
    }

    /// Return the next event, the one failure that ends a failed attempt, or `None` after the end. The event borrows
    /// the stream until the next call. A drop of the returned future loses no event, so `select!` can race it.
    pub async fn next(&mut self) -> Option<Result<Event<'_>, Failure>> {
        match self.state {
            State::Ended => None,
            State::Failed(failure) => Some(Err(self.fail(failure))),
            State::Streaming => match self.fill().await {
                Ok(true) => {
                    let index = self.next_event;
                    self.next_event += 1;
                    let event = self.reducer.draft().event(index, &self.payload);
                    self.info.output_seen |= event.carries_output();
                    Some(Ok(event))
                }
                Ok(false) => None,
                Err(failure) => Some(Err(self.fail(failure))),
            },
        }
    }

    fn fail(&mut self, failure: Failure) -> Failure {
        self.state = State::Ended;
        failure
    }

    /// Take the attempt facts out of a stream that ended.
    pub(crate) fn take_info(&mut self) -> AttemptInfo {
        std::mem::take(&mut self.info)
    }

    /// Decode payloads until an event is pending. Return false at the end of the answer.
    async fn fill(&mut self) -> Result<bool, Failure> {
        while self.next_event == self.reducer.draft().pending() {
            // Nothing after the end of an answer counts, as the OpenAI SDK stops at `[DONE]`.
            if self.reducer.draft().done {
                self.state = State::Ended;
                return Ok(false);
            }
            self.reducer.draft_mut().clear_events();
            self.next_event = 0;
            let utf8 = self.next_payload().await?;
            // A payload that is no UTF-8 text is no JSON document.
            let decoded = if utf8 {
                self.reducer.decode(&self.payload)
            } else {
                Err(DecodeError::Protocol)
            };
            match decoded {
                Ok(None) => {}
                Ok(Some(kind)) => {
                    let max_error_body = self.reducer.draft().limits.max_error_body_bytes;
                    let data = self.payload.as_bytes();
                    self.info.error_body = Some(data[..data.len().min(max_error_body)].to_vec());
                    return Err(Failure::Provider(kind));
                }
                // A payload that the end of the stream cut short is a truncation, not a malformed answer.
                Err(DecodeError::Protocol) => {
                    return Err(if self.parser.cut {
                        Failure::IncompleteStream
                    } else {
                        Failure::Protocol
                    });
                }
                Err(DecodeError::TooLarge) => return Err(Failure::ResponseTooLarge),
            }
        }
        Ok(true)
    }

    /// Read the next payload into `payload`. Return false when it is no UTF-8 text.
    async fn next_payload(&mut self) -> Result<bool, Failure> {
        // A cancelled read can return here, so the buffer goes back only once.
        if std::mem::take(&mut self.payload_lent) {
            self.parser.restore(std::mem::take(&mut self.payload).into_bytes());
        }
        loop {
            match self
                .parser
                .next(self.body_ended)
                .map_err(|_| Failure::ResponseTooLarge)?
            {
                Step::Payload => {
                    return Ok(match String::from_utf8(self.parser.take_payload()) {
                        Ok(text) => {
                            self.payload = text;
                            self.payload_lent = true;
                            true
                        }
                        Err(error) => {
                            self.parser.restore(error.into_bytes());
                            false
                        }
                    });
                }
                Step::End => return Err(Failure::IncompleteStream),
                Step::NeedMore => {
                    let Some(body) = self.body.as_mut() else {
                        return Err(Failure::IncompleteStream);
                    };
                    match transport::next_chunk(body).await {
                        Some(Ok(chunk)) => self.parser.feed(chunk),
                        Some(Err(fault)) => return Err(Failure::Transport(fault)),
                        None => self.body_ended = true,
                    }
                }
            }
        }
    }
}

/// Read at most `max` bytes of a failed answer. A peer fault leaves no detail.
async fn read_error_body(body: &mut BoxBody, max: usize) -> Option<Vec<u8>> {
    let mut bytes = Vec::new();
    while bytes.len() < max {
        match transport::next_chunk(body).await {
            Some(Ok(chunk)) => bytes.extend_from_slice(&chunk[..chunk.len().min(max - bytes.len())]),
            Some(Err(_)) => return None,
            None => break,
        }
    }
    Some(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Target;
    use crate::encoder::Encoder;
    use crate::request::OriginRef;
    use crate::request::{Block, Origin, Request};
    use crate::testing::{CannedTransport, OVERLOAD_EVENT, block_on, canned_reply, frame, target};
    use crate::transport::{Fault, Outgoing};
    use testing::read_trace;

    fn canned_text_reply() -> String {
        [
            r#"{"type":"message_start","message":{"usage":{"input_tokens":100,"cache_read_input_tokens":20}}}"#,
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
            r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
            r#"{"type":"message_stop"}"#,
        ]
        .map(frame)
        .concat()
    }

    /// Open a stream over a canned reply.
    fn open_canned(canned: &CannedTransport) -> Stream {
        open_with(canned, Protocol::AnthropicMessages)
    }

    fn open_with(canned: &CannedTransport, protocol: Protocol) -> Stream {
        let request = Encoded {
            http: Outgoing::new("https://example.test/v1/messages", &[], b""),
            protocol,
            origin: OriginRef {
                model: "m",
                base_url: "",
            },
        };
        block_on(Stream::open(canned, &request, Options::default()))
    }

    #[test]
    fn events_survive_fragmented_reads() {
        // A 7-byte chunk splits SSE events across reads, so the parser holds state across reads.
        let canned = CannedTransport::new(canned_text_reply()).chunk_size(7);
        let mut stream = open_canned(&canned);
        // The cache subsets belong to input.
        assert_eq!(
            read_trace(&mut stream),
            "start 0 text\n\
             text_delta 0 \"Hel\"\n\
             text_delta 0 \"lo\"\n\
             stop 0 text\n\
             done stop \"end_turn\" input=120 output=5 cache_read=20"
        );
        assert_eq!(stream.info().error_body, None);
    }

    // Some servers close the stream right after the last `data:` line (openai/openai-node#2725).
    #[test]
    fn unterminated_last_event_vs_truncation() {
        let reply = canned_text_reply();
        let whole = &reply[..reply.len() - 2];
        let prefix: String = reply.split_inclusive("\n\n").take(3).collect();
        for (bytes, expected) in [
            (
                whole,
                "start 0 text\ntext_delta 0 \"Hel\"\ntext_delta 0 \"lo\"\nstop 0 text\ndone stop \"end_turn\" input=120 output=5 cache_read=20",
            ),
            (
                &whole[..whole.len() - 3],
                "start 0 text\ntext_delta 0 \"Hel\"\ntext_delta 0 \"lo\"\nstop 0 text\nfailed IncompleteStream",
            ),
            (
                prefix.as_str(),
                "start 0 text\ntext_delta 0 \"Hel\"\nfailed IncompleteStream",
            ),
        ] {
            let canned = CannedTransport::new(bytes.to_owned());
            let mut stream = open_canned(&canned);
            assert_eq!(read_trace(&mut stream), expected);
            assert_eq!(stream.info().error_body, None);
        }
    }

    #[test]
    fn keeps_error_event_bytes() {
        let failed_event = r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#;
        let canned = CannedTransport::new(frame(failed_event));
        let mut stream = open_canned(&canned);
        assert_eq!(read_trace(&mut stream), "failed server_error");
        assert_eq!(stream.info().error_body.as_deref(), Some(failed_event.as_bytes()));
        // The provider answered 200, so only the event names the failure.
        assert_eq!(stream.info().status, Some(200));
    }

    #[test]
    fn output_seen_turns_on_with_the_first_output() {
        let canned = CannedTransport::new(canned_text_reply());
        let mut stream = open_canned(&canned);
        assert!(!stream.info().output_seen);
        assert!(matches!(block_on(stream.next()), Some(Ok(Event::BlockStarted(_)))));
        assert!(stream.info().output_seen);

        let refused = CannedTransport::new("busy").status(503);
        let mut stream = open_canned(&refused);
        assert!(matches!(block_on(stream.next()), Some(Err(_))));
        assert!(!stream.info().output_seen);
    }

    #[test]
    fn malformed_event_keeps_no_bytes() {
        // Malformed JSON and text that is not UTF-8 fail each of the three decoders, and the stream keeps no bytes.
        for protocol in [
            Protocol::AnthropicMessages,
            Protocol::OpenaiChat,
            Protocol::OpenaiResponses,
        ] {
            for body in [frame("{not json").into_bytes(), b"data: \xff\n\n".to_vec()] {
                let canned = CannedTransport::new(body);
                let mut stream = open_with(&canned, protocol);
                assert_eq!(read_trace(&mut stream), "failed Protocol", "{protocol:?}");
                assert_eq!(stream.info().error_body, None);
            }
        }
    }

    // The stream keeps the body past the end of the answer, and the drop of the stream closes the body.
    #[test]
    fn body_lives_until_drop() {
        let truncated = frame(r#"{"type":"message_start","message":{"usage":{"input_tokens":1}}}"#);
        for (bytes, status, early, expected) in [
            (
                canned_reply(),
                200,
                false,
                "start 0 text\ntext_delta 0 \"Hello from the mock provider.\"\nstop 0 text\ndone stop \"end_turn\" output=8",
            ),
            (canned_reply(), 200, true, "start 0 text"),
            (truncated, 200, false, "failed IncompleteStream"),
            (OVERLOAD_EVENT.to_owned(), 503, false, "failed server_error"),
        ] {
            let canned = CannedTransport::new(bytes).status(status);
            let mut stream = open_canned(&canned);
            let trace = if early {
                testing::item_line(&block_on(stream.next()).unwrap())
            } else {
                read_trace(&mut stream)
            };
            assert_eq!(trace, expected);
            assert_eq!(canned.opens(), 1);
            assert_eq!(canned.closes(), 0);
            drop(stream);
            assert_eq!(canned.closes(), 1);
        }
    }

    // A retry may repeat only a request the provider never received, so the fault decides the delivery.
    #[test]
    fn open_fault_is_terminal_and_records_delivery() {
        for (cause, delivery) in [
            (Fault::ConnectFailed, Delivery::DefinitelyUnsent),
            (Fault::ConnectTimeout, Delivery::DefinitelyUnsent),
            (Fault::ConnectionLost, Delivery::PossiblySent),
            (Fault::IdleTimeout, Delivery::PossiblySent),
        ] {
            let canned = CannedTransport::new(String::new())
                .open_error(cause)
                .request_id("never-read");
            let mut stream = open_canned(&canned);
            assert_eq!(block_on(stream.next()), Some(Err(Failure::Transport(cause))));
            assert_eq!(stream.info().delivery, delivery);
            assert_eq!(block_on(stream.next()), None);
            // No head was read, so nothing of one is known.
            assert_eq!(stream.info().request_id, None);
            assert_eq!(stream.info().status, None);
            assert_eq!(canned.closes(), 0);
        }
    }

    #[test]
    fn stream_keeps_origin_across_encodes() {
        let thinking_reply = [
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"why","signature":"sig"}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
            r#"{"type":"message_stop"}"#,
        ]
        .map(frame)
        .concat();
        let mut encoder = Encoder::new();
        let canned = CannedTransport::new(thinking_reply);
        let target = target(Protocol::AnthropicMessages);
        let blocks = [Block::user_text("hello")];
        let encoded = encoder.encode(&target, Request::new(&blocks)).unwrap();
        // A retry opens the same bytes with no second encode.
        let mut first = block_on(Stream::open(&canned, &encoded, Options::default()));
        while block_on(first.next()).is_some() {}
        let mut stream = block_on(Stream::open(&canned, &encoded, Options::default()));
        // The next encode reuses the storage the first one lent, for another model.
        let other = Target {
            model: "another-model-with-a-longer-name".into(),
            ..target.clone()
        };
        let long = "new".repeat(10_000);
        let blocks = [Block::user_text(&long)];
        encoder.encode(&other, Request::new(&blocks)).unwrap();
        let mut origin = None;
        while let Some(event) = block_on(stream.next()) {
            if let Event::BlockStopped(stopped) = event.unwrap()
                && let crate::BlockResult::Reasoning(Some(replay)) = stopped.result
            {
                origin = Some(Origin::from(replay.origin));
            }
        }
        let origin = origin.unwrap();
        assert_eq!(origin.model, "test-model");
        assert_eq!(origin.base_url, "https://example.test/v1");
        assert_eq!(canned.opens(), 2);
    }

    // `select!` drops the future of the branch that lost, so a dropped `next` must lose no event.
    #[test]
    fn dropped_next_loses_no_event() {
        // One byte per chunk puts a wait between every line and the blank line that ends its event.
        let canned = CannedTransport::new(canned_text_reply()).chunk_size(1).wait_first();
        let mut stream = open_canned(&canned);
        let mut lines = Vec::new();
        let mut drops = 0;
        loop {
            let mut next = std::pin::pin!(stream.next());
            let mut cx = std::task::Context::from_waker(std::task::Waker::noop());
            match next.as_mut().poll(&mut cx) {
                std::task::Poll::Ready(Some(item)) => lines.push(testing::item_line(&item)),
                std::task::Poll::Ready(None) => break,
                std::task::Poll::Pending => drops += 1,
            }
        }
        assert!(drops > 10, "the body waited {drops} times");
        assert_eq!(
            lines.join("\n"),
            "start 0 text\n\
             text_delta 0 \"Hel\"\n\
             text_delta 0 \"lo\"\n\
             stop 0 text\n\
             done stop \"end_turn\" input=120 output=5 cache_read=20"
        );
    }
}
