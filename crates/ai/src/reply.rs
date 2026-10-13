//! One attempt, read to its end into an owned [`Response`]. [`Reply::next`] lends each event and keeps what it says.
//! [`Reply::finish`] returns the response after `done`, and an [`AttemptError`] otherwise.

use crate::encoder::Encoded;
use crate::failure::Failure;
use crate::request::{Reasoning, ReasoningReplay};
use crate::response::{AttemptError, BlockKind, BlockResult, Completion, Content, Event, Partial, Response};
use crate::stream::{Options, Stream};
use crate::transport::Transport;

/// The events of one attempt, then its owned [`Response`].
#[derive(Debug)]
pub struct Reply {
    /// Read it only through [`Reply::next`], so every event reaches the reply.
    stream: Stream,
    /// One entry per block, in start order. Blocks can interleave, so each block joins its deltas in its own buffer.
    parts: Vec<Part>,
    end: End,
}

#[derive(Debug)]
enum Part {
    /// A block and the text it joined so far. A block cut off by the end of the attempt never stops.
    Open(BlockKind, String),
    Stopped(Content),
}

#[derive(Debug)]
enum End {
    Open,
    /// The end of the answer, with no content yet.
    Done(Completion),
    Failed(Failure),
}

impl Reply {
    /// Open one attempt. Borrow `request` only until this returns. An opening fault, and an answer other than 200,
    /// become the first event.
    pub async fn open(transport: &dyn Transport, request: &Encoded<'_>, options: Options) -> Reply {
        Reply {
            stream: Stream::open(transport, request, options).await,
            parts: Vec::new(),
            end: End::Open,
        }
    }

    /// Return the next event, the one failure that ends a failed attempt, or `None` after the end. The reply keeps what
    /// the event says. The event borrows the reply until the next call. A drop of the returned future loses no event,
    /// so `select!` can race it.
    pub async fn next(&mut self) -> Option<Result<Event<'_>, Failure>> {
        let item = self.stream.next().await?;
        match &item {
            Ok(event) => keep(&mut self.parts, &mut self.end, event),
            Err(failure) => self.end = End::Failed(*failure),
        }
        Some(item)
    }

    /// Read the rest of the attempt, and return the response or the failure. Both own every byte.
    ///
    /// # Errors
    ///
    /// Returns [`AttemptError`] if the attempt failed. It holds the cause, the attempt facts, and the partial output.
    pub async fn finish(mut self) -> Result<Response, AttemptError> {
        while self.next().await.is_some() {}
        let info = self.stream.take_info();
        match self.end {
            End::Done(completion) => Ok(Response {
                info,
                completion: Completion {
                    content: complete(self.parts),
                    ..completion
                },
            }),
            End::Failed(cause) => Err(AttemptError {
                cause,
                info,
                partial: partial(self.parts),
            }),
            End::Open => unreachable!("a stream ends with `done` or a failure"),
        }
    }

    /// Stop the attempt, close its stream, and return the partial output of the events so far. A call cut off in its
    /// arguments is not in the output.
    pub fn cancel(self) -> Vec<Partial> {
        partial(self.parts)
    }
}

/// Keep what one event says.
fn keep(parts: &mut Vec<Part>, end: &mut End, event: &Event<'_>) {
    match event {
        Event::BlockStarted(started) => parts.push(Part::Open(started.kind, String::new())),
        Event::TextDelta(delta) | Event::RefusalDelta(delta) | Event::ReasoningDelta(delta) => {
            if let Part::Open(_, text) = &mut parts[delta.block as usize] {
                text.push_str(delta.text);
            }
        }
        // The text already joins its sections. A stopped tool carries authoritative arguments.
        Event::ReasoningSectionStarted(_) | Event::ToolInputDelta(_) => {}
        Event::BlockStopped(stopped) => {
            let part = &mut parts[stopped.block as usize];
            if let Part::Open(_, text) = part {
                let text = std::mem::take(text);
                *part = Part::Stopped(match stopped.result {
                    BlockResult::Text => Content::Text(text),
                    BlockResult::Refusal => Content::Refusal(text),
                    BlockResult::Reasoning(replay) => Content::Reasoning(Reasoning {
                        text,
                        replay: replay.map(ReasoningReplay::from),
                    }),
                    BlockResult::ToolCall(call) => Content::ToolCall(call.into()),
                });
            }
        }
        Event::Done(done) => {
            *end = End::Done(Completion {
                content: Vec::new(),
                finish_reason: done.finish_reason,
                raw_finish_reason: done.raw_finish_reason.to_owned(),
                usage: done.usage,
            });
        }
    }
}

/// Pack the stopped blocks in start order. Each stopped part owns its content, so the response costs no second copy.
fn complete(parts: Vec<Part>) -> Vec<Content> {
    parts
        .into_iter()
        .filter_map(|part| match part {
            Part::Open(..) => None,
            Part::Stopped(content) => Some(content),
        })
        .collect()
}

/// Keep the text of every block and each complete tool call, in start order. Provider state never survives a
/// failure.
fn partial(parts: Vec<Part>) -> Vec<Partial> {
    parts
        .into_iter()
        .filter_map(|part| {
            let (text_part, text): (fn(String) -> Partial, String) = match part {
                Part::Stopped(Content::ToolCall(call)) => return Some(Partial::ToolCall(call)),
                // A call cut off in its arguments does not exist.
                Part::Open(BlockKind::ToolCall, _) => return None,
                Part::Open(BlockKind::Text, text) | Part::Stopped(Content::Text(text)) => (Partial::Text, text),
                Part::Open(BlockKind::Refusal, text) | Part::Stopped(Content::Refusal(text)) => {
                    (Partial::Refusal, text)
                }
                Part::Open(BlockKind::Reasoning, text) | Part::Stopped(Content::Reasoning(Reasoning { text, .. })) => {
                    (Partial::Reasoning, text)
                }
            };
            (!text.is_empty()).then(|| text_part(text))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::encoder::Encoder;
    use crate::failure::ProviderKind;
    use crate::request::{Block, Protocol, Request, Role, ToolCall};
    use crate::response::{AttemptInfo, FinishReason, ResponseLimits, Usage};
    use crate::testing::{
        CannedTransport, OVERLOAD_EVENT, block_on, canned_reply, completion, frame, generate_text, generate_with,
        target,
    };
    use crate::transport::Fault;

    /// Open a reply over a canned Anthropic answer.
    fn open_canned(canned: &CannedTransport) -> Reply {
        let mut encoder = Encoder::new();
        let blocks = [Block::user_text("hello")];
        let encoded = encoder
            .encode(&target(Protocol::AnthropicMessages), Request::new(&blocks))
            .unwrap();
        block_on(Reply::open(canned, &encoded, Options::default()))
    }

    fn info(response: &Result<Response, AttemptError>) -> &AttemptInfo {
        match response {
            Ok(response) => &response.info,
            Err(error) => &error.info,
        }
    }

    fn failed(response: &Result<Response, AttemptError>) -> &AttemptError {
        match response {
            Err(error) => error,
            Ok(response) => panic!("the attempt completed: {response:?}"),
        }
    }

    #[test]
    fn finish_after_early_stop_reads_the_rest() {
        let canned = CannedTransport::new(canned_reply());
        let mut reply = open_canned(&canned);
        assert!(matches!(block_on(reply.next()), Some(Ok(Event::BlockStarted(_)))));
        let response = block_on(reply.finish());
        assert_eq!(completion(&response).text(), "Hello from the mock provider.");
        assert_eq!(canned.opens(), 1);
        assert_eq!(canned.closes(), 1);
    }

    #[test]
    fn cancel_returns_the_text_that_streamed_and_closes_the_stream() {
        let canned = CannedTransport::new(canned_reply());
        let mut reply = open_canned(&canned);
        assert!(matches!(block_on(reply.next()), Some(Ok(Event::BlockStarted(_)))));
        assert!(matches!(block_on(reply.next()), Some(Ok(Event::TextDelta(_)))));

        let partial = reply.cancel();

        assert_eq!(partial, [Partial::Text("Hello from the mock provider.".to_owned())]);
        assert_eq!(canned.closes(), 1);
    }

    #[test]
    fn failed_reply_keeps_text_and_complete_calls() {
        let mut bytes = [
            r#"{"type":"message_start","message":{"usage":{}}}"#,
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"why","signature":"sig"}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
            r#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"run"}}"#,
            r#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#,
            r#"{"type":"content_block_stop","index":1}"#,
            r#"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_2","name":"cut"}}"#,
            r#"{"type":"content_block_start","index":3,"content_block":{"type":"text","text":"dra"}}"#,
            r#"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"ft"}}"#,
            // A block that streamed no text leaves no part.
            r#"{"type":"content_block_start","index":4,"content_block":{"type":"text","text":""}}"#,
            r#"{"type":"content_block_stop","index":4}"#,
            r#"{"type":"content_block_start","index":5,"content_block":{"type":"thinking","thinking":""}}"#,
            r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        ]
        .map(frame)
        .concat();
        bytes.push_str(&canned_reply()); // The reader never reaches the complete response after the failure.
        let canned = CannedTransport::new(bytes);
        let response = block_on(open_canned(&canned).finish());
        let failed = failed(&response);
        assert_eq!(failed.cause, Failure::Provider(ProviderKind::ServerError));
        // The reply drained the events, so the failure records that output reached the library caller.
        assert!(info(&response).output_seen);
        // A failed reply keeps the stopped reasoning without its signature, the complete call, and the text. It drops the
        // call that the failure cut off.
        assert_eq!(
            failed.partial,
            [
                Partial::Reasoning("why".into()),
                Partial::ToolCall(ToolCall {
                    call_id: "toolu_1".into(),
                    name: "run".into(),
                    arguments: "{}".into()
                }),
                Partial::Text("draft".into()),
            ]
        );
        assert_eq!(
            Block::from(failed.partial[0].clone()),
            Block::Reasoning(Reasoning {
                text: "why".to_string(),
                replay: None
            })
        );
    }

    // Interleaved blocks stop out of order. Final arguments replace fragments, and one tool is dropped.
    fn interleaved_prefix() -> String {
        [
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text"}}"#,
            r#"{"type":"response.output_text.delta","output_index":0,"delta":"A"}"#,
            r#"{"type":"response.output_item.added","output_index":1,"item":{"type":"reasoning","id":"r"}}"#,
            r#"{"type":"response.reasoning_summary_text.delta","output_index":1,"summary_index":0,"delta":"think"}"#,
            r#"{"type":"response.output_item.added","output_index":2,"item":{"type":"function_call","call_id":"call","name":"read"}}"#,
            r#"{"type":"response.function_call_arguments.delta","output_index":2,"delta":"partial"}"#,
            r#"{"type":"response.output_item.added","output_index":3,"item":{"type":"message"}}"#,
            r#"{"type":"response.content_part.added","output_index":3,"content_index":0,"part":{"type":"refusal"}}"#,
            r#"{"type":"response.refusal.delta","output_index":3,"delta":"refused"}"#,
            r#"{"type":"response.output_item.added","output_index":4,"item":{"type":"message"}}"#,
            r#"{"type":"response.content_part.added","output_index":4,"content_index":0,"part":{"type":"output_text"}}"#,
            r#"{"type":"response.output_text.delta","output_index":4,"delta":"B"}"#,
            r#"{"type":"response.output_item.done","output_index":4,"item":{"type":"message"}}"#,
            r#"{"type":"response.output_text.done","output_index":4}"#,
            r#"{"type":"response.function_call_arguments.done","output_index":2,"arguments":"{}"}"#,
            r#"{"type":"response.output_item.done","output_index":2,"item":{"type":"function_call","status":"completed","arguments":"{}"}}"#,
            r#"{"type":"response.output_text.done","output_index":0}"#,
            r#"{"type":"response.refusal.done","output_index":3}"#,
            r#"{"type":"response.output_item.done","output_index":1,"item":{"type":"reasoning","id":"r","encrypted_content":"encrypted"}}"#,
            r#"{"type":"response.output_item.added","output_index":5,"item":{"type":"function_call","call_id":"dropped","name":"read"}}"#,
        ]
        .map(frame)
        .concat()
    }

    fn interleaved_reply() -> String {
        interleaved_prefix()
            + &frame(
                r#"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":10,"output_tokens":20,"input_tokens_details":{"cached_tokens":2,"cache_write_tokens":1},"output_tokens_details":{"reasoning_tokens":3}}}}"#,
            )
    }

    #[test]
    fn non_200_answer_keeps_status_request_id_and_bounded_body() {
        let long = "x".repeat(ResponseLimits::default().max_error_body_bytes + 1);
        let larger = "y".repeat(9_001);
        let cases = [
            (
                429,
                r#"{"error":{"code":"rate_limit_exceeded"}}"#,
                ProviderKind::RateLimited,
                ResponseLimits::default(),
                7,
            ),
            (
                503,
                long.as_str(),
                ProviderKind::ServerError,
                ResponseLimits::default(),
                7,
            ),
            (
                503,
                OVERLOAD_EVENT,
                ProviderKind::ServerError,
                ResponseLimits {
                    max_error_body_bytes: 8,
                    ..ResponseLimits::default()
                },
                7,
            ),
            (
                400,
                larger.as_str(),
                ProviderKind::BadStatus,
                ResponseLimits {
                    max_error_body_bytes: 9_000,
                    ..ResponseLimits::default()
                },
                333,
            ),
        ];
        for (status, bytes, kind, limits, chunk_size) in cases {
            let canned = CannedTransport::new(bytes.to_owned())
                .status(status)
                .request_id("req-http")
                .chunk_size(chunk_size);
            let response = generate_with(
                &canned,
                &target(Protocol::AnthropicMessages),
                "hello",
                Options { limits, deadline: None },
            );
            assert_eq!(canned.closes(), 1);
            assert_eq!(failed(&response).cause, Failure::Provider(kind));
            assert_eq!(info(&response).status, Some(status));
            assert_eq!(info(&response).request_id.as_deref(), Some("req-http"));
            let kept = &bytes.as_bytes()[..bytes.len().min(limits.max_error_body_bytes)];
            assert_eq!(info(&response).error_body.as_deref(), Some(kept));
        }
    }

    #[test]
    fn faults_keep_attempt_info() {
        for during_open in [false, true] {
            let canned = CannedTransport::new(canned_reply()).request_id("req-exchange");
            let canned = if during_open {
                canned.open_error(Fault::ConnectionLost)
            } else {
                canned.read_error(Fault::ConnectionLost)
            };
            let response = generate_text(&canned, &target(Protocol::AnthropicMessages), "hello");
            assert_eq!(failed(&response).cause, Failure::Transport(Fault::ConnectionLost));
            // An open that failed read no head. A read that failed keeps the head it read.
            let request_id = if during_open { None } else { Some("req-exchange") };
            assert_eq!(info(&response).request_id.as_deref(), request_id);
            assert_eq!(canned.closes(), usize::from(!during_open));
        }
    }

    #[test]
    fn error_body_read_fault_keeps_status_class() {
        let canned = CannedTransport::new(String::new())
            .status(503)
            .read_error(Fault::ConnectionLost);
        let response = generate_text(&canned, &target(Protocol::AnthropicMessages), "hello");
        assert_eq!(failed(&response).cause, Failure::Provider(ProviderKind::ServerError));
        assert_eq!(info(&response).error_body, None);
        assert_eq!(canned.closes(), 1);
    }

    #[test]
    fn failed_reply_closes_opened_body() {
        let cases = [
            (interleaved_prefix() + &frame(OVERLOAD_EVENT), Protocol::OpenaiResponses),
            (frame(OVERLOAD_EVENT), Protocol::AnthropicMessages),
            (frame("not JSON"), Protocol::AnthropicMessages),
        ];
        for (bytes, protocol) in cases {
            let canned = CannedTransport::new(bytes);
            let response = generate_text(&canned, &target(protocol), "hello");
            assert!(response.is_err());
            assert_eq!(canned.closes(), 1);
        }
    }

    #[test]
    fn refusal_is_separate_content() {
        let reply = [
            r#"{"choices":[{"index":0,"delta":{"content":"Sorry. "},"finish_reason":null}]}"#,
            r#"{"choices":[{"index":0,"delta":{"refusal":"I cannot help"},"finish_reason":"stop"}]}"#,
        ]
        .map(frame)
        .concat()
            + "data: [DONE]\n\n";
        let canned = CannedTransport::new(reply);
        let response = generate_text(&canned, &target(Protocol::OpenaiChat), "hello");
        let completion = completion(&response);
        assert_eq!(completion.finish_reason, FinishReason::Refusal);
        assert_eq!(completion.text(), "Sorry. ");
        assert_eq!(completion.content[1], Content::Refusal("I cannot help".into()));
        let replayed = Block::from(completion.content[1].clone());
        assert_eq!(replayed.role(), Role::Assistant);
        assert_eq!(replayed, Block::assistant_text("I cannot help"));
    }

    #[test]
    fn limits_reach_stream() {
        let two_blocks = [
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"a"}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
            r#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":"b"}}"#,
        ]
        .map(frame)
        .concat();
        for (bytes, limits) in [
            (
                two_blocks,
                ResponseLimits {
                    max_blocks: 1,
                    ..ResponseLimits::default()
                },
            ),
            (
                canned_reply(),
                ResponseLimits {
                    max_response_bytes: 64,
                    ..ResponseLimits::default()
                },
            ),
            (
                canned_reply(),
                ResponseLimits {
                    max_response_bytes: 0,
                    ..ResponseLimits::default()
                },
            ),
        ] {
            let canned = CannedTransport::new(bytes);
            let response = generate_with(
                &canned,
                &target(Protocol::AnthropicMessages),
                "hello",
                Options { limits, deadline: None },
            );
            assert_eq!(failed(&response).cause, Failure::ResponseTooLarge);
        }
    }

    #[test]
    fn half_megabyte_answer_fits_default_limits() {
        // About 0.5 MB of text, the largest output a model emits, with quotes that double under JSON escaping.
        let piece = "say \"hi\" ";
        let pieces = 60_000;
        let mut reply = [
            r#"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message"}}"#,
            r#"{"type":"response.content_part.added","output_index":0,"content_index":0,"part":{"type":"output_text"}}"#,
        ]
        .map(frame)
        .concat();
        for _ in 0..pieces {
            reply.push_str("data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"item_id\":\"msg_1\",\"delta\":\"say \\\"hi\\\" \"}\n\n");
        }
        reply.push_str(&frame(r#"{"type":"response.output_text.done","output_index":0}"#));
        // Both final events repeat the whole text, escaped.
        for (head, tail) in [
            (
                "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"",
                "\"}]}}\n\n",
            ),
            (
                "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{},\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"",
                "\"}]}]}}\n\n",
            ),
        ] {
            reply.push_str(head);
            for _ in 0..pieces {
                reply.push_str("say \\\"hi\\\" ");
            }
            reply.push_str(tail);
        }
        let canned = CannedTransport::new(reply);
        let response = generate_text(&canned, &target(Protocol::OpenaiResponses), "hello");
        assert_eq!(completion(&response).text(), piece.repeat(pieces));
    }

    #[test]
    fn collects_interleaved_content_and_metadata() {
        let canned = CannedTransport::new(interleaved_reply()).request_id("req-owned");
        let response = generate_text(&canned, &target(Protocol::OpenaiResponses), "hello");
        assert_eq!(canned.closes(), 1);
        drop(canned);
        let completion = completion(&response);
        assert_eq!(info(&response).request_id.as_deref(), Some("req-owned"));
        assert_eq!(completion.finish_reason, FinishReason::Refusal);
        assert_eq!(completion.raw_finish_reason, "completed");
        assert_eq!(
            completion.usage,
            Usage {
                input: 10,
                output: 20,
                reasoning: 3,
                cache_read: 2,
                cache_write: 1
            }
        );
        assert_eq!(completion.content.len(), 5);
        assert_eq!(completion.content[0], Content::Text("A".into()));
        let Content::Reasoning(Reasoning {
            text,
            replay: Some(replay),
        }) = &completion.content[1]
        else {
            panic!("{:?}", completion.content[1])
        };
        assert_eq!(text, "think");
        assert_eq!(replay.kind, crate::ReplayKind::ResponsesEncrypted);
        assert_eq!(replay.data, "encrypted");
        assert_eq!(
            completion.content[2],
            Content::ToolCall(ToolCall {
                call_id: "call".into(),
                name: "read".into(),
                arguments: "{}".into()
            })
        );
        assert_eq!(completion.content[3], Content::Refusal("refused".into()));
        assert_eq!(completion.content[4], Content::Text("B".into()));
    }

    #[test]
    fn every_event_boundary_prefix_fails() {
        let reply = interleaved_reply();
        let ends: Vec<usize> = reply
            .match_indices("\n\n")
            .map(|(at, _)| at + 2)
            .filter(|&end| end != reply.len())
            .collect();
        for end in ends {
            let canned = CannedTransport::new(reply[..end].to_owned()).request_id("req-prefix");
            let response = generate_text(&canned, &target(Protocol::OpenaiResponses), "hello");
            assert_eq!(failed(&response).cause, Failure::IncompleteStream);
            assert_eq!(info(&response).request_id.as_deref(), Some("req-prefix"));
            assert_eq!(canned.closes(), 1);
        }
    }

    // The answer is whole at its end event, as the OpenAI SDK stops at `[DONE]`, so nothing after it can undo it.
    #[test]
    fn stops_reading_after_answer_ends() {
        for trailer in ["not JSON", OVERLOAD_EVENT] {
            let canned = CannedTransport::new(format!("{}data: {trailer}\n\n", canned_reply()));
            let response = generate_text(&canned, &target(Protocol::AnthropicMessages), "hello");
            assert_eq!(completion(&response).text(), "Hello from the mock provider.");
            assert_eq!(completion(&response).finish_reason, FinishReason::Stop);
            assert_eq!(canned.closes(), 1);
        }
    }
}
