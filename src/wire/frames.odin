package wire


// Top-level application frame shells.

// Client request frame with typed method params. The discriminator `type` is
// written first, then `id`, then `method` before `params` so a streaming decoder
// can resolve the params type before reading them.
Request :: struct {
    // Discriminator; must be `"request"`.
    type:   string,

    // Client-generated correlation id.
    id:     Request_Id,

    // RPC method name.
    method: Method_Name,

    // Method params typed by `method`.
    params: Request_Params,
}

// Build a typed request with the fixed discriminator.
request_build :: proc(id: Request_Id, method: Method_Name, params: Request_Params) -> Request {
    return Request{type = "request", id = id, method = method, params = params}
}

// Write `type`, `id`, `method`, then `params` (omitted when the method's params
// are all default).
request_emit :: proc(e: ^Emitter, self: Request) {
    object_begin(e)
    field_string(e, "type", self.type)
    field_u64(e, "id", u64(self.id))
    field_string(e, "method", method_name_to_wire(self.method))

    if !params_are_default(self.params) {
        key(e, "params")
        request_params_emit(e, self.params)
    }

    object_end(e)
}

// Verify discriminator, id range, and params bounds.
request_validate :: proc(self: Request) -> Validation_Error {
    if self.type != "request" {
        return .Bad_Frame_Type
    }

    if u64(self.id) == 0 || u64(self.id) > MAX_REQUEST_ID {
        return .Out_Of_Range
    }

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

// Server response frame. Success is the `"response"` frame; failure is the
// `"error"` frame — the outcome is the frame `type`, not a boolean flag.
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

// Write `type` first: a success frame `{"type":"response",…}` or an error frame
// `{"type":"error",…}`.
response_emit :: proc(e: ^Emitter, self: Response) {
    object_begin(e)

    switch v in self {
    case Response_Ok:
        field_string(e, "type", "response")
        field_u64(e, "id", u64(v.id))
        key(e, "result")
        response_result_emit(e, v.result)

    case Response_Error:
        field_string(e, "type", "error")
        field_u64(e, "id", u64(v.id))
        key(e, "error")
        error_object_emit(e, v.error)
    }

    object_end(e)
}

// Verify id range and result/error bounds.
response_validate :: proc(self: Response) -> Validation_Error {
    switch v in self {
    case Response_Ok:
        if u64(v.id) == 0 || u64(v.id) > MAX_REQUEST_ID {
            return .Out_Of_Range
        }

        return response_result_validate(v.result)

    case Response_Error:
        if u64(v.id) == 0 || u64(v.id) > MAX_REQUEST_ID {
            return .Out_Of_Range
        }

        return error_object_validate(v.error)
    }

    return .None
}

// Server-pushed broadcast frame.
Broadcast :: struct {
    // Discriminator; must be `"broadcast"`.
    type: string,

    // Broadcast name.
    name: Broadcast_Name,

    // Typed broadcast payload.
    data: Broadcast_Data,
}

// Build a broadcast frame with the fixed discriminator.
broadcast_build :: proc(name: Broadcast_Name, data: Broadcast_Data) -> Broadcast {
    return Broadcast{type = "broadcast", name = name, data = data}
}

// Write `type`, then `name`, then `data`.
broadcast_emit :: proc(e: ^Emitter, self: Broadcast) {
    object_begin(e)
    field_string(e, "type", "broadcast")
    field_string(e, "name", broadcast_name_to_wire(self.name))
    key(e, "data")
    broadcast_data_emit(e, self.data)
    object_end(e)
}

// Verify the broadcast payload bounds.
broadcast_validate :: proc(self: Broadcast) -> Validation_Error {
    return broadcast_data_validate(self.data)
}

// Deep-copy a broadcast frame into `allocator` to retain it past its decode arena.
broadcast_clone :: proc(self: Broadcast, allocator := context.allocator) -> Broadcast {
    return broadcast_build(self.name, broadcast_data_clone(self.data, allocator))
}

// First client frame on a connection, or a request.
Client_Frame :: union {
    Client_Hello,
    Request,
}

// Write a client frame.
client_frame_emit :: proc(e: ^Emitter, self: Client_Frame) {
    switch v in self {
    case Client_Hello:
        client_hello_emit(e, v)

    case Request:
        request_emit(e, v)
    }
}

// Which kind of server frame a received object is.
Server_Frame_Kind :: enum {
    // A `hello` snapshot.
    Hello,

    // A successful `response` frame.
    Response,

    // An `error` response frame.
    Error,

    // A `broadcast` frame.
    Broadcast,
}

// Enough of a received server frame to dispatch it: its kind plus the id (for a
// response/error) or the raw name (for a broadcast). The caller resolves the
// pending request method from `id`, then types the body with response_from_value
// / broadcast_from_value.
Server_Frame_Header :: struct {
    // Which kind of frame this is.
    kind: Server_Frame_Kind,

    // Correlation id, for a response or error frame.
    id:   Request_Id,

    // Raw broadcast name, for a broadcast frame.
    name: string,
}

// --- streaming decoders ---

// Decode a request straight from the token stream. Resolve `method` with a scan first,
// so `params` can be typed even when object members arrive in another order.
request_from_reader :: proc(d: ^Decoder) -> (out: Request, err: Validation_Error) {
    out.type = "request"
    dec_object_begin(d) or_return
    // Resolve `method` up front so `params` can be typed regardless of member order.
    ms := dec_find_tag(d, "method") or_return
    method := enum_from_wire_checked(method_name_wire, ms) or_return
    out.method = method

    Field :: enum {
        Id,
        Params,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "type":
            out.type = dec_string(d) or_return

        case "id":
            out.id = Request_Id(dec_u64(d) or_return)
            seen += {.Id}

        case "method":
            dec_skip(d) or_return

        case "params":
            out.params = request_params_from_reader(method, d) or_return
            seen += {.Params}

        case:
            dec_skip(d) or_return
        }
    }

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

// Decode a response once the request method is known from the pending-id map. The
// success frame is `"response"`; the failure frame is `"error"`.
response_from_reader :: proc(method: Method_Name, d: ^Decoder) -> (out: Response, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "response":
        id: Request_Id
        result: Response_Result

        Field :: enum {
            Id,
            Result,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "id":
                id = Request_Id(dec_u64(d) or_return)
                seen += {.Id}

            case "result":
                result = response_result_from_reader(method, d) or_return
                seen += {.Result}

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Id, .Result} {
            return nil, .Mismatched_Payload
        }

        return Response_Ok{id = id, result = result}, .None

    case "error":
        id: Request_Id
        eo: Error_Object

        Field :: enum {
            Id,
            Err,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "id":
                id = Request_Id(dec_u64(d) or_return)
                seen += {.Id}

            case "error":
                eo = error_object_from_reader(d) or_return
                seen += {.Err}

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Id, .Err} {
            return nil, .Mismatched_Payload
        }

        return Response_Error{id = id, error = eo}, .None
    }

    return nil, .Mismatched_Payload
}

// Decode a broadcast straight from the token stream. `name` precedes `data`
// (normative), so the typed payload is streamed once the name is known. An unknown
// name is rejected; a receiver that skips unknown broadcasts uses
// `server_frame_header_stream` to route before touching the payload.
broadcast_from_reader :: proc(d: ^Decoder) -> (out: Broadcast, err: Validation_Error) {
    out.type = "broadcast"
    dec_object_begin(d) or_return
    // Resolve `name` up front so `data` can be typed regardless of member order.
    ns := dec_find_tag(d, "name") or_return
    name := enum_from_wire_checked(broadcast_name_wire, ns) or_return
    out.name = name

    Field :: enum {
        Data,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "type":
            ts := dec_string(d) or_return

            if ts != "broadcast" {
                return {}, .Bad_Frame_Type
            }

        case "name":
            dec_skip(d) or_return

        case "data":
            out.data = broadcast_data_from_reader(name, d) or_return
            seen += {.Data}

        case:
            dec_skip(d) or_return
        }
    }

    if .Data not_in seen {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

// Decode a client frame (`client.hello` or `request`) straight from the token stream.
client_frame_from_reader :: proc(d: ^Decoder) -> (out: Client_Frame, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "client.hello":
        h: Client_Hello
        h.type = "client.hello"
        h.protocol = PROTOCOL_VERSION

        Field :: enum {
            Client,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "protocol":
                h.protocol = u32(dec_u64(d) or_return)

            case "client":
                h.client = client_from_reader(d) or_return
                seen += {.Client}

            case:
                dec_skip(d) or_return
            }
        }

        if .Client not_in seen {
            return nil, .Mismatched_Payload
        }

        return h, .None

    case "request":
        req: Request
        req.type = "request"
        // Resolve `method` up front so `params` can be typed regardless of order.
        ms := dec_find_tag(d, "method") or_return
        method := enum_from_wire_checked(method_name_wire, ms) or_return
        req.method = method

        Field :: enum {
            Id,
            Params,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "id":
                req.id = Request_Id(dec_u64(d) or_return)
                seen += {.Id}

            case "method":
                dec_skip(d) or_return

            case "params":
                req.params = request_params_from_reader(method, d) or_return
                seen += {.Params}

            case:
                dec_skip(d) or_return
            }
        }

        if .Id not_in seen {
            return nil, .Mismatched_Payload
        }

        if .Params not_in seen {
            if dp, has := default_params(method).?; has {
                req.params = dp
            } else {
                return nil, .Mismatched_Payload
            }
        }

        return req, .None
    }

    return nil, .Mismatched_Payload
}

// Tier-1 streaming header scan: read a server frame's kind and routing key (`id`
// for a response/error, `name` for a broadcast) by streaming only the leading
// keys, then STOP — the (possibly multi-MB) `result`/`data` is never materialized.
// The caller resolves the pending method from `id`, then decodes the body with
// `response_from_reader` / `broadcast_from_reader`, or drops an unknown broadcast
// without ever touching its payload.
server_frame_header_stream :: proc(
    data: string,
    allocator := context.allocator,
) -> (
    out: Server_Frame_Header,
    err: Validation_Error,
) {
    d := decoder_init(data, allocator)
    dec_object_begin(&d) or_return
    // Frame member order is not significant; scan for `type` and the routing key so a
    // non-first discriminator is still routed without materializing its payload.
    // Header parsing deliberately translates a malformed/missing frame tag to the
    // more specific public error instead of propagating Mismatched_Payload verbatim.
    tag, terr := dec_find_tag(&d, "type")

    if terr != .None {
        return {}, .Bad_Frame_Type
    }

    switch tag {
    case "hello":
        out.kind = .Hello
        return out, .None

    case "response", "error":
        out.kind = tag == "response" ? .Response : .Error
        for {
            k, kdone := dec_key(&d) or_return
            if kdone do break

            if k == "id" {
                out.id = Request_Id(dec_u64(&d) or_return)
                return out, .None
            }

            dec_skip(&d) or_return
        }

        return {}, .Mismatched_Payload

    case "broadcast":
        out.kind = .Broadcast
        for {
            k, kdone := dec_key(&d) or_return
            if kdone do break

            if k == "name" {
                out.name = dec_string(&d) or_return
                return out, .None
            }

            dec_skip(&d) or_return
        }

        return {}, .Mismatched_Payload
    }

    return {}, .Bad_Frame_Type
}
