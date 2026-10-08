//! Convert SSE bytes into `data` payloads, joined with a newline and emitted on a blank line. The parser resumes
//! across chunks, and copies only a line that crosses a chunk boundary.

use bytes::Bytes;

/// A size bound stopped the parser.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TooLarge;

/// What one [`Sse::next`] call found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Step {
    /// A payload is ready. Take it with [`Sse::take_payload`] before the next call.
    Payload,
    /// The parser needs the next chunk.
    NeedMore,
    /// The stream ended.
    End,
}

/// A line that [`Sse::read_line`] found.
enum Line {
    /// The line lies in the current chunk, between these offsets.
    InChunk(usize, usize),
    /// The line crossed a chunk boundary, so `line` holds it.
    Copied,
    NeedMore,
    End,
}

/// The parser state. The source owns input bytes until they are consumed.
#[derive(Debug)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "each flag is one state of the line and event machine"
)]
pub(crate) struct Sse {
    /// Bound the whole response, so it cannot grow memory without bound.
    max_total: usize,
    /// Bound one line and the joined data of one event. The escaped JSON envelope counts toward this bound.
    max_event: usize,
    /// The start of a line that crossed a chunk boundary.
    line: Vec<u8>,
    /// The joined data of the event.
    data: Vec<u8>,
    /// The event holds at least one data line.
    data_seen: bool,
    /// The bytes the parser consumed from the source.
    total: usize,
    /// True before the first complete line. The first line may start with a BOM.
    at_start: bool,
    /// True when the previous byte was a CR. The next LF completes the CRLF terminator.
    saw_cr: bool,
    /// The last payload ended with the stream, not with a blank line, so the stream may have cut it.
    pub(crate) cut: bool,
    chunk: Bytes,
    /// The offset of the first unconsumed byte in `chunk`.
    pos: usize,
}

impl Sse {
    pub(crate) fn new(max_total: usize, max_event: usize) -> Self {
        Sse {
            max_total,
            max_event,
            line: Vec::new(),
            data: Vec::new(),
            data_seen: false,
            total: 0,
            at_start: true,
            saw_cr: false,
            cut: false,
            chunk: Bytes::new(),
            pos: 0,
        }
    }

    /// Give the parser the next chunk. Call it only after [`Step::NeedMore`].
    pub(crate) fn feed(&mut self, chunk: Bytes) {
        debug_assert_eq!(self.pos, self.chunk.len());
        self.chunk = chunk;
        self.pos = 0;
    }

    /// Take the payload of the last [`Step::Payload`], and start the next event. Give the buffer back with
    /// [`Sse::restore`], so its capacity serves the next event.
    pub(crate) fn take_payload(&mut self) -> Vec<u8> {
        self.data_seen = false;
        std::mem::take(&mut self.data)
    }

    /// Give back the buffer that [`Sse::take_payload`] took.
    pub(crate) fn restore(&mut self, mut buffer: Vec<u8>) {
        buffer.clear();
        self.data = buffer;
    }

    /// Find the next payload. `ended` tells that the source holds no more chunks.
    pub(crate) fn next(&mut self, ended: bool) -> Result<Step, TooLarge> {
        loop {
            let (line, copied) = match self.read_line(ended)? {
                Line::NeedMore => return Ok(Step::NeedMore),
                Line::End => {
                    // Some servers close the stream without the blank line after the last event, so a pending payload
                    // still counts, as the OpenAI SDK reads it (openai/openai-node#2725).
                    self.cut = self.data_seen;
                    return Ok(if self.data_seen { Step::Payload } else { Step::End });
                }
                Line::InChunk(start, end) => (&self.chunk[start..end], false),
                Line::Copied => (&self.line[..], true),
            };
            // Drop the byte-order mark that can lead the first line of a response.
            let line = if std::mem::replace(&mut self.at_start, false) {
                line.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(line)
            } else {
                line
            };
            let payload = if line.is_empty() {
                self.data_seen
            } else {
                if line[0] != b':' {
                    // A line that starts with a colon is an SSE comment. A field other than data is ignored.
                    let (field, value) = match memchr::memchr(b':', line) {
                        Some(colon) => (&line[..colon], &line[colon + 1..]),
                        None => (line, &line[line.len()..]),
                    };
                    if field == b"data" {
                        let value = value.strip_prefix(b" ").unwrap_or(value);
                        let separator: &[u8] = if self.data_seen { b"\n" } else { b"" };
                        if separator.len() + value.len() > self.max_event - self.data.len() {
                            return Err(TooLarge);
                        }
                        self.data.extend_from_slice(separator);
                        self.data.extend_from_slice(value);
                        self.data_seen = true;
                    }
                }
                false
            };
            if copied {
                self.line.clear();
            }
            if payload {
                return Ok(Step::Payload);
            }
        }
    }

    /// Find one line without its terminator.
    fn read_line(&mut self, ended: bool) -> Result<Line, TooLarge> {
        loop {
            let rest = &self.chunk[self.pos..];
            if rest.is_empty() {
                if !ended {
                    return Ok(Line::NeedMore);
                }
                // A last line without its terminator still counts.
                return Ok(if self.line.is_empty() { Line::End } else { Line::Copied });
            }
            // A CR ended the previous line. The next LF is the second half of a CRLF terminator.
            if self.saw_cr {
                self.saw_cr = false;
                if rest[0] == b'\n' {
                    self.consume(1)?;
                    continue;
                }
            }
            let end = memchr::memchr2(b'\n', b'\r', rest).unwrap_or(rest.len());
            if end > self.max_event - self.line.len() {
                return Err(TooLarge);
            }
            if end == rest.len() {
                // The line runs past the chunk, so the parser must copy it into the line buffer.
                self.line.extend_from_slice(rest);
                self.consume(end)?;
                continue;
            }
            self.saw_cr = rest[end] == b'\r';
            let start = self.pos;
            self.consume(end + 1)?;
            if self.line.is_empty() {
                return Ok(Line::InChunk(start, start + end));
            }
            self.line.extend_from_slice(&self.chunk[start..start + end]);
            return Ok(Line::Copied);
        }
    }

    fn consume(&mut self, count: usize) -> Result<(), TooLarge> {
        if count > self.max_total - self.total {
            return Err(TooLarge);
        }
        self.total += count;
        self.pos += count;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Run the parser over `chunks` in order, and copy each payload, because the parser reuses its buffer.
    fn frame_with(chunks: &[&[u8]], max_total: usize, max_event: usize) -> Result<Vec<Vec<u8>>, TooLarge> {
        let mut sse = Sse::new(max_total, max_event);
        let mut chunks = chunks.iter();
        let mut ended = false;
        let mut out = Vec::new();
        loop {
            match sse.next(ended)? {
                Step::Payload => {
                    let payload = sse.take_payload();
                    out.push(payload.clone());
                    sse.restore(payload);
                }
                Step::NeedMore => match chunks.next() {
                    Some(chunk) => sse.feed(Bytes::copy_from_slice(chunk)),
                    None => ended = true,
                },
                Step::End => return Ok(out),
            }
        }
    }

    fn frame(chunks: &[&[u8]]) -> Vec<Vec<u8>> {
        frame_with(chunks, usize::MAX, usize::MAX).unwrap()
    }

    #[test]
    fn splits_at_every_byte_boundary() {
        let whole = b"data: {\"x\":1}\r\n\r\ndata: {\"y\":2}\r\n\r\ndata: [DONE]\r\n\r\n";
        let singles: Vec<&[u8]> = whole.chunks(1).collect();
        assert_eq!(frame(&singles), [&b"{\"x\":1}"[..], b"{\"y\":2}", b"[DONE]"]);
    }

    #[test]
    fn line_endings_and_multiline_data() {
        // A dropped CR state reads the same as success unless the case holds two data lines.
        type Case = (&'static [&'static [u8]], &'static [&'static [u8]]);
        let cases: [Case; 4] = [
            (&[b"event: message_start\ndata: {\"a\":1}\n\n"], &[b"{\"a\":1}"]),
            (&[b"data: a\r\ndata: b\r\n\r\n"], &[b"a\nb"]),
            (
                &[b"data: {\"x\":1}\r\rdata: {\"y\":2}\r\r"],
                &[b"{\"x\":1}", b"{\"y\":2}"],
            ),
            (&[b"data: a\ndata: b\n\n"], &[b"a\nb"]),
        ];
        for (chunks, want) in cases {
            assert_eq!(frame(chunks), want, "chunks: {chunks:?}");
        }
    }

    #[test]
    fn strips_leading_bom_once() {
        assert_eq!(
            frame(&[b"\xEF\xBB\xBFdata: hi\n\n\xEF\xBB\xBFdata: ignored\n\ndata: \xEF\xBB\xBFinside\n\n"]),
            [&b"hi"[..], b"\xEF\xBB\xBFinside"]
        );
    }

    #[test]
    fn unterminated_last_event_counts() {
        for tail in [&b"data: last\n"[..], b"data: last"] {
            assert_eq!(
                frame(&[b"data: {\"done\":1}\n\n", tail]),
                [&b"{\"done\":1}"[..], b"last"]
            );
        }
    }

    #[test]
    fn bounds_are_exact() {
        // One line has 16 bytes: the six bytes of "data: " and ten data bytes.
        let cases: [(&[&[u8]], usize, usize, bool); 8] = [
            (&[b"data: 0123456789\r\n\r\n"], 64, 16, true),
            (&[b"data: 0123456789A\r\n\r\n"], 64, 16, false),
            // A line that crosses a chunk boundary counts whole.
            (&[b"data: 01234", b"56789\n\n"], 64, 16, true),
            (&[b"data: 01234", b"56789A\n\n"], 64, 16, false),
            // The joined data "0123456\n01234567" is exactly 16 bytes.
            (&[b"data: 0123456\ndata: 01234567\n\n"], 64, 16, true),
            (&[b"data: 0123456\ndata: 012345678\n\n"], 64, 16, false),
            // The total limit counts every byte, terminators included.
            (&[b"data: x\n\n"], 9, 16, true),
            (&[b"data: x\n\n"], 8, 16, false),
        ];
        for (input, max_total, max_event, ok) in cases {
            let got = frame_with(input, max_total, max_event);
            if ok {
                assert_eq!(got.map(|payloads| payloads.len()), Ok(1), "case: {input:?}");
            } else {
                assert_eq!(got, Err(TooLarge), "case: {input:?}");
            }
        }
    }
}
