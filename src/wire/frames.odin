package wire

// Client request frame with typed method params.
Request :: struct {
    // Correlation id, echoed verbatim in the response.
    id:     Request_Id,

    // RPC method name.
    method: Method_Name,

    // Method params typed by `method`.
    params: Request_Params,
}

// Build a typed request.
request_build :: proc(id: Request_Id, method: Method_Name, params: Request_Params) -> Request {
    return Request{id = id, method = method, params = params}
}

// Write a request; `params` is omitted when the method's params are all default.
request_emit :: proc(e: ^Emitter, self: Request) {
    object_begin(e)
    field_string(e, "jsonrpc", JSONRPC_VERSION)
    field_request_id(e, "id", self.id)
    field_string(e, "method", method_name_to_wire(self.method))

    if !params_are_default(self.params) {
        key(e, "params")
        request_params_emit(e, self.params)
    }

    object_end(e)
}

// Encode a request; the caller owns the returned emitter (`to_string` then destroy).
// `ok` is false when a write was truncated, leaving incomplete JSON that must not be sent.
request_encode :: proc(self: Request, allocator := context.allocator) -> (e: Emitter, ok: bool) {
    emitter_init(&e, allocator)
    request_emit(&e, self)

    return e, !emitter_failed(&e)
}

// Verify the id shape and params bounds.
request_validate :: proc(self: Request) -> Validation_Error {
    req_id_validate(self.id) or_return
    return request_params_validate(self.params)
}

// Successful server response; carries the typed method result.
Response_Ok :: struct {
    // Correlation id copied from the request.
    id:     Request_Id,

    // Method result, tagged by the request method that produced it.
    result: Response_Result,
}

// Failed server response; carries a method-agnostic error object.
Response_Error :: struct {
    // Correlation id copied from the request.
    id:    Request_Id,

    // Request failure details.
    error: Error_Object,
}

// Server response frame. One frame shape carrying exactly one of `result` /
// `error`; the outcome is which member is present.
Response :: union {
    Response_Ok,
    Response_Error,
}

// Build a successful response frame.
response_ok_build :: proc(id: Request_Id, result: Response_Result) -> Response {
    return Response_Ok{id = id, result = result}
}

// Build a failed response frame.
response_error_build :: proc(id: Request_Id, error: Error_Object) -> Response {
    return Response_Error{id = id, error = error}
}

// Write a response: `jsonrpc`, `id`, then `result` or `error`, never both.
response_emit :: proc(e: ^Emitter, self: Response) {
    assert(self != nil, "a response frame carries either a result or an error")
    object_begin(e)
    field_string(e, "jsonrpc", JSONRPC_VERSION)

    switch v in self {
    case Response_Ok:
        field_request_id(e, "id", v.id)
        key(e, "result")
        response_result_emit(e, v.result)

    case Response_Error:
        field_request_id(e, "id", v.id)
        key(e, "error")
        error_object_emit(e, v.error)
    }

    object_end(e)
}

// Encode a response; the caller owns the returned emitter (`to_string` then destroy).
// `ok` is false when a write was truncated, leaving incomplete JSON that must not be sent.
response_encode :: proc(self: Response, allocator := context.allocator) -> (e: Emitter, ok: bool) {
    emitter_init(&e, allocator)
    response_emit(&e, self)

    return e, !emitter_failed(&e)
}

// Verify the id shape and result/error bounds.
response_validate :: proc(self: Response) -> Validation_Error {
    switch v in self {
    case Response_Ok:
        req_id_validate(v.id) or_return

        return response_result_validate(v.result)

    case Response_Error:
        req_id_validate(v.id) or_return

        return error_object_validate(v.error)
    }

    return .None
}

// Server-pushed notification: a request object with no `id`, so nothing replies.
// Ordering, replay, gating, and droppability are ours — see `broadcast_name_class`,
// `Seq`, and `session.resync`.
Notification :: struct {
    // Broadcast name, occupying the same `method` namespace as requests.
    method: Broadcast_Name,

    // Typed broadcast payload.
    params: Broadcast_Data,
}

// Build a notification frame.
notification_build :: proc(method: Broadcast_Name, params: Broadcast_Data) -> Notification {
    return {method = method, params = params}
}

// Write a notification: `jsonrpc`, `method`, `params`. No `id`.
notification_emit :: proc(e: ^Emitter, self: Notification) {
    object_begin(e)
    field_string(e, "jsonrpc", JSONRPC_VERSION)
    field_string(e, "method", broadcast_name_to_wire(self.method))
    key(e, "params")
    broadcast_data_emit(e, self.params)
    object_end(e)
}

// Encode a notification; the caller owns the returned emitter (`to_string` then destroy).
// `ok` is false when a write was truncated, leaving incomplete JSON that must not be sent.
notification_encode :: proc(self: Notification, allocator := context.allocator) -> (e: Emitter, ok: bool) {
    emitter_init(&e, allocator)
    notification_emit(&e, self)

    return e, !emitter_failed(&e)
}

// Write a notification whose `params` are already encoded. The durable path logs the
// payload and ships it nested in one frame, so both come from a single emit and cannot
// disagree; `params` must be what `broadcast_data_emit` wrote for `method`.
notification_emit_raw :: proc(e: ^Emitter, method: Broadcast_Name, params: string) {
    object_begin(e)
    field_string(e, "jsonrpc", JSONRPC_VERSION)
    field_string(e, "method", broadcast_name_to_wire(method))
    key(e, "params")
    val_raw(e, params)
    object_end(e)
}

// Verify the notification payload bounds.
notification_validate :: proc(self: Notification) -> Validation_Error {
    return broadcast_data_validate(self.params)
}

// Deep-copy a notification frame into `allocator` to retain it past its decode arena.
notification_clone :: proc(self: Notification, allocator := context.allocator) -> Notification {
    return notification_build(self.method, broadcast_data_clone(self.params, allocator))
}

// Which kind of server frame a received object is.
Server_Frame_Kind :: enum {
    // A response carrying `result`.
    Response,

    // A response carrying `error`.
    Error,

    // A notification: `method` with no `id`.
    Notification,
}

// Enough of a received server frame to dispatch it: its kind plus the id (for a
// response) or the raw method name (for a notification). The caller resolves the
// pending request method from `id`, then types the body with `response_from_reader`
// / `notification_from_reader`, or drops an unknown notification untouched.
Server_Frame_Header :: struct {
    // Which kind of frame this is.
    kind:   Server_Frame_Kind,

    // Correlation id, for a response.
    id:     Request_Id,

    // Raw method name, for a notification.
    method: string,
}

// Consume a frame's opening `{`. A non-object root — notably a batch array — is a
// framing violation rather than a payload mismatch.
@(private)
dec_frame_begin :: proc(d: ^Decoder) -> Validation_Error {
    if dec_object_begin(d) != .None {
        return .Bad_Frame_Type
    }

    return .None
}

// Read and verify the `jsonrpc` member's value.
@(private)
dec_jsonrpc :: proc(d: ^Decoder) -> Validation_Error {
    s := dec_string(d) or_return

    if s != JSONRPC_VERSION {
        return .Bad_Frame_Type
    }

    return .None
}

// Decode a request straight from the token stream. Resolve `method` with a scan
// first, so `params` can be typed even when object members arrive in another order.
request_from_reader :: proc(d: ^Decoder) -> (out: Request, err: Validation_Error) {
    dec_frame_begin(d) or_return
    ms := dec_find_tag(d, "method") or_return
    method := enum_from_wire_checked(method_name_wire, ms) or_return
    out.method = method

    Field :: enum {
        Jsonrpc,
        Id,
        Method,
        Params,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "jsonrpc":
            if .Jsonrpc in seen do return {}, .Bad_Frame_Type
            dec_jsonrpc(d) or_return
            seen += {.Jsonrpc}

        case "id":
            if .Id in seen do return {}, .Bad_Frame_Type
            out.id = Request_Id(dec_raw_scalar(d) or_return)
            seen += {.Id}

        case "method":
            if .Method in seen do return {}, .Bad_Frame_Type
            dec_skip(d) or_return
            seen += {.Method}

        case "params":
            if .Params in seen do return {}, .Bad_Frame_Type
            out.params = request_params_from_reader(method, d) or_return
            seen += {.Params}

        case:
            dec_skip(d) or_return
        }
    }

    if .Jsonrpc not_in seen {
        return {}, .Bad_Frame_Type
    }

    // An id-less request is a notification, and this implementation defines none
    // in the client-to-server direction.
    if .Id not_in seen {
        return {}, .Mismatched_Payload
    }

    if .Params not_in seen {
        if dp, has := default_params(method).?; has {
            out.params = dp
        } else {
            return {}, .Mismatched_Payload
        }
    }

    return out, .None
}

// Decode a response once the request method is known from the pending-id map.
// Exactly one of `result` / `error` must be present.
response_from_reader :: proc(method: Method_Name, d: ^Decoder) -> (out: Response, err: Validation_Error) {
    dec_frame_begin(d) or_return
    id: Request_Id
    result: Response_Result
    eo: Error_Object

    Field :: enum {
        Jsonrpc,
        Id,
        Result,
        Err,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "jsonrpc":
            if .Jsonrpc in seen do return nil, .Bad_Frame_Type
            dec_jsonrpc(d) or_return
            seen += {.Jsonrpc}

        case "id":
            if .Id in seen do return nil, .Bad_Frame_Type
            id = Request_Id(dec_raw_scalar(d) or_return)
            seen += {.Id}

        case "result":
            if .Result in seen do return nil, .Bad_Frame_Type
            result = response_result_from_reader(method, d) or_return
            seen += {.Result}

        case "error":
            if .Err in seen do return nil, .Bad_Frame_Type
            eo = error_object_from_reader(d) or_return
            seen += {.Err}

        case:
            dec_skip(d) or_return
        }
    }

    if .Jsonrpc not_in seen {
        return nil, .Bad_Frame_Type
    }

    if .Id not_in seen {
        return nil, .Mismatched_Payload
    }

    switch seen & {.Result, .Err} {
    case {.Result}:
        return Response_Ok{id = id, result = result}, .None

    case {.Err}:
        return Response_Error{id = id, error = eo}, .None
    }

    return nil, .Mismatched_Payload
}

// Decode a notification straight from the token stream. `method` precedes `params`
// (normative), so the typed payload is streamed once the name is known. An unknown
// name is rejected; a receiver that skips unknown notifications uses
// `server_frame_header_stream` to route before touching the payload.
notification_from_reader :: proc(d: ^Decoder) -> (out: Notification, err: Validation_Error) {
    dec_frame_begin(d) or_return
    ms := dec_find_tag(d, "method") or_return
    method := enum_from_wire_checked(broadcast_name_wire, ms) or_return
    out.method = method

    Field :: enum {
        Jsonrpc,
        Method,
        Params,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "jsonrpc":
            if .Jsonrpc in seen do return {}, .Bad_Frame_Type
            dec_jsonrpc(d) or_return
            seen += {.Jsonrpc}

        case "method":
            if .Method in seen do return {}, .Bad_Frame_Type
            dec_skip(d) or_return
            seen += {.Method}

        case "params":
            if .Params in seen do return {}, .Bad_Frame_Type
            out.params = broadcast_data_from_reader(method, d) or_return
            seen += {.Params}

        case:
            dec_skip(d) or_return
        }
    }

    if .Jsonrpc not_in seen {
        return {}, .Bad_Frame_Type
    }

    if .Params not_in seen {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

// Tier-1 header scan: classify a server frame by which members are present and read
// its routing key, without materializing the (possibly multi-MB) `result`/`params`.
// The caller then resolves the pending method from `id` and decodes the body, or
// drops an unknown notification untouched.
//
// Routes on member keys alone: a normative-order frame stops at `result`/`error`
// without reading the payload. A payload-before-`id` peer costs one `dec_skip` walk.
server_frame_header_stream :: proc(
    data: string,
    allocator := context.allocator,
) -> (
    out: Server_Frame_Header,
    err: Validation_Error,
) {
    d := decoder_init(data, allocator)
    dec_frame_begin(&d) or_return
    has_id := false
    has_jsonrpc := false
    kind: Maybe(Server_Frame_Kind)
    scan: for {
        k, done := dec_key(&d) or_return
        if done do break

        // Skip after the exit check, so a routed payload is never walked.
        skip_value := false

        switch k {
        case "jsonrpc":
            dec_jsonrpc(&d) or_return
            has_jsonrpc = true

        case "id":
            out.id = Request_Id(dec_raw_scalar(&d) or_return)
            has_id = true

        case "method":
            out.method = dec_string(&d) or_return
            kind = .Notification

        case "result", "error":
            kind = k == "result" ? Server_Frame_Kind.Response : Server_Frame_Kind.Error
            skip_value = true

        case:
            skip_value = true
        }

        // A notification routes on `method` alone; a response also needs its id.
        if seen_kind, ok := kind.?; ok && has_jsonrpc && (seen_kind == .Notification || has_id) {
            break scan
        }

        if skip_value {
            dec_skip(&d) or_return
        }
    }

    if !has_jsonrpc {
        return {}, .Bad_Frame_Type
    }

    resolved, ok := kind.?

    if !ok {
        return {}, .Bad_Frame_Type
    }

    // A response must correlate; a notification must not.
    if (resolved == .Notification) == has_id {
        return {}, .Bad_Frame_Type
    }

    out.kind = resolved

    return out, .None
}
