/*
package sse is a sans-I/O Server-Sent Events (text/event-stream) parser. It
takes raw byte chunks and dispatches completed `data:` payloads through a
callback; it does no I/O and knows nothing about HTTP framing, curl, or TLS.

`feed` reuses the parser's internal buffer between events, so the `data`
string handed to `On_Event` borrows the parser and is valid for the call
only — the same borrow-for-the-call-only contract as `websocket.On_Message`.
Callers that need to keep a payload must copy it before returning.

Line and event sizes are bounded (`Config.max_line_bytes`,
`Config.max_event_bytes`); bounds violations return an `Error` rather than
asserting, since they are wire input, not internal state.
*/
package sse
