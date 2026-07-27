package wire

import "core:strings"
import "core:testing"

@(test)
test_request_roundtrip :: proc(t: ^testing.T) {
    input := `{"jsonrpc":"2.0","id":2,"method":"session.cancel_input","params":{"session_id":"0011223344556677","input_id":7}}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    req, derr := request_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, req.method, Method_Name.Session_Cancel_Input)
    testing.expect_value(t, string(req.id), "2")
    testing.expect(t, request_validate(req) == .None, "request should validate")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    request_emit(&e, req)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_response_ok_roundtrip :: proc(t: ^testing.T) {
    input := `{"jsonrpc":"2.0","id":3,"result":{"type":"queued","input_id":8}}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    resp, derr := response_from_reader(.Session_Send_Input, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, ok := resp.(Response_Ok)
    testing.expect(t, ok, "should be a success response")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    response_emit(&e, resp)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_response_error_roundtrip :: proc(t: ^testing.T) {
    input := `{"jsonrpc":"2.0","id":4,"error":{"code":-31015,"message":"busy"}}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    resp, derr := response_from_reader(.Session_List, &v)
    testing.expect(t, derr == .None, "decode should succeed")
    re, ok := resp.(Response_Error)
    testing.expect(t, ok, "should be an error response")
    testing.expect_value(t, re.error.code, Error_Code.Session_Busy)
    testing.expect(t, response_validate(resp) == .None, "error response should validate")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    response_emit(&e, resp)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_notification_roundtrip :: proc(t: ^testing.T) {
    input := `{"jsonrpc":"2.0","method":"notice","params":{"level":"warn","source":"provider","message":"rate limited"}}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    n, derr := notification_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, n.method, Broadcast_Name.Notice)

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    notification_emit(&e, n)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_server_frame_header_dispatch :: proc(t: ^testing.T) {
    {
        // The scan reads `id` plus the result/error discriminant and stops before
        // the result is ever materialized.
        h, err := server_frame_header_stream(`{"jsonrpc":"2.0","id":9,"result":{}}`, context.temp_allocator)
        testing.expect(t, err == .None, "header parse should succeed")
        testing.expect_value(t, h.kind, Server_Frame_Kind.Response)
        testing.expect_value(t, string(h.id), "9")
    }
    {
        h, err := server_frame_header_stream(
            `{"jsonrpc":"2.0","id":9,"error":{"code":-32603,"message":"x"}}`,
            context.temp_allocator,
        )
        testing.expect(t, err == .None, "header parse should succeed")
        testing.expect_value(t, h.kind, Server_Frame_Kind.Error)
    }
    {
        // A notification's `method` is read without touching the (possibly huge) params.
        h, err := server_frame_header_stream(
            `{"jsonrpc":"2.0","method":"run.done","params":{}}`,
            context.temp_allocator,
        )
        testing.expect(t, err == .None, "header parse should succeed")
        testing.expect_value(t, h.kind, Server_Frame_Kind.Notification)
        testing.expect_value(t, h.method, "run.done")
    }

    free_all(context.temp_allocator)
}

@(test)
test_request_omitted_params_roundtrip :: proc(t: ^testing.T) {
    input := `{"jsonrpc":"2.0","id":1,"method":"catalog.refresh"}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    req, derr := request_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, req.method, Method_Name.Catalog_Refresh)

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    request_emit(&e, req)
    testing.expect_value(t, to_string(&e), input)
}

// `jsonrpc` is required and must be exactly the string "2.0".
@(test)
test_frames_require_jsonrpc_version :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    cases := []string {
        `{"id":1,"method":"catalog.refresh"}`,
        `{"jsonrpc":"1.0","id":1,"method":"catalog.refresh"}`,
        `{"jsonrpc":2.0,"id":1,"method":"catalog.refresh"}`,
        `{"jsonrpc":"2.00","id":1,"method":"catalog.refresh"}`,
    }
    for input in cases {
        v := decoder_init(input, context.temp_allocator)
        _, derr := request_from_reader(&v)
        testing.expect(t, derr != .None, "a bad or absent jsonrpc member must be rejected")
    }
}

// Batching is unsupported: a top-level array is a framing violation, not a payload
// mismatch, so it maps to Invalid Request rather than Invalid Params.
@(test)
test_frames_reject_batch_array :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    input := `[{"jsonrpc":"2.0","id":1,"method":"catalog.refresh"}]`

    v := decoder_init(input, context.temp_allocator)
    _, derr := request_from_reader(&v)
    testing.expect_value(t, derr, Validation_Error.Bad_Frame_Type)

    h, herr := server_frame_header_stream(input, context.temp_allocator)
    testing.expect_value(t, herr, Validation_Error.Bad_Frame_Type)
    testing.expect_value(t, h.kind, Server_Frame_Kind.Response)
}

// Any id JSON-RPC permits round-trips byte-identically, including a quoted string
// and null, because the token text is echoed unparsed.
@(test)
test_request_id_echoes_verbatim :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    ids := []string{`7`, `"9zo2a2xb"`, `null`, `"a-b_c.d"`, `0`}
    for id in ids {
        input := strings.concatenate({`{"jsonrpc":"2.0","id":`, id, `,"result":{}}`}, context.temp_allocator)

        v := decoder_init(input, context.temp_allocator)
        resp, derr := response_from_reader(.Session_Remove, &v)
        testing.expect(t, derr == .None, "every permitted id form must decode")

        ok, is_ok := resp.(Response_Ok)
        testing.expect(t, is_ok, "should be a success response")
        testing.expect_value(t, string(ok.id), id)
        testing.expect(t, response_validate(resp) == .None, "an echoed id must validate")

        e: Emitter
        emitter_init(&e, context.temp_allocator)
        response_emit(&e, resp)
        testing.expect_value(t, to_string(&e), input)
    }
}

// A response carries exactly one of `result` / `error`.
@(test)
test_response_requires_exactly_one_outcome :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    both := `{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":-32603,"message":"x"}}`
    v := decoder_init(both, context.temp_allocator)
    _, derr := response_from_reader(.Session_Remove, &v)
    testing.expect(t, derr != .None, "a response with both result and error must be rejected")

    neither := `{"jsonrpc":"2.0","id":1}`
    v2 := decoder_init(neither, context.temp_allocator)
    _, derr2 := response_from_reader(.Session_Remove, &v2)
    testing.expect(t, derr2 != .None, "a response with neither result nor error must be rejected")
}

// A response must correlate and a notification must not.
@(test)
test_frame_shape_id_presence :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    _, e1 := server_frame_header_stream(
        `{"jsonrpc":"2.0","id":1,"method":"run.done","params":{}}`,
        context.temp_allocator,
    )
    testing.expect(t, e1 != .None, "a notification carrying an id must be rejected")

    _, e2 := server_frame_header_stream(`{"jsonrpc":"2.0","result":{}}`, context.temp_allocator)
    testing.expect(t, e2 != .None, "a response with no id must be rejected")
}

// A request with no `id` would be a client notification, and none are defined.
@(test)
test_request_requires_id :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    v := decoder_init(`{"jsonrpc":"2.0","method":"catalog.refresh"}`, context.temp_allocator)
    _, derr := request_from_reader(&v)
    testing.expect(t, derr != .None, "an id-less request must be rejected")
}

// A duplicated envelope member is rejected rather than resolved first- or last-wins,
// so a peer and an intermediary can never disagree on which value is authoritative.
@(test)
test_frames_reject_duplicate_envelope_members :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    requests := []string {
        `{"jsonrpc":"2.0","jsonrpc":"2.0","id":1,"method":"catalog.refresh"}`,
        `{"jsonrpc":"2.0","id":1,"id":2,"method":"catalog.refresh"}`,
        `{"jsonrpc":"2.0","id":1,"method":"catalog.refresh","method":"catalog.refresh"}`,
    }
    for input in requests {
        v := decoder_init(input, context.temp_allocator)
        _, derr := request_from_reader(&v)
        testing.expect_value(t, derr, Validation_Error.Bad_Frame_Type)
    }

    v := decoder_init(`{"jsonrpc":"2.0","id":1,"result":{},"result":{}}`, context.temp_allocator)
    _, derr := response_from_reader(.Session_Remove, &v)
    testing.expect_value(t, derr, Validation_Error.Bad_Frame_Type)

    notice := `{"level":"warn","source":"provider","message":"rate limited"}`
    notifications := []string {
        strings.concatenate(
            {`{"jsonrpc":"2.0","jsonrpc":"2.0","method":"notice","params":`, notice, `}`},
            context.temp_allocator,
        ),
        strings.concatenate(
            {`{"jsonrpc":"2.0","method":"notice","method":"notice","params":`, notice, `}`},
            context.temp_allocator,
        ),
        strings.concatenate(
            {`{"jsonrpc":"2.0","method":"notice","params":`, notice, `,"params":`, notice, `}`},
            context.temp_allocator,
        ),
    }
    for input in notifications {
        v2 := decoder_init(input, context.temp_allocator)
        _, derr2 := notification_from_reader(&v2)
        testing.expect_value(t, derr2, Validation_Error.Bad_Frame_Type)
    }
}

// `rpc.`-prefixed method names are reserved by JSON-RPC for system extensions and
// must never appear in either registry.
@(test)
test_no_method_uses_the_reserved_rpc_prefix :: proc(t: ^testing.T) {
    for m in Method_Name {
        testing.expect(t, !strings.has_prefix(method_name_wire[m], "rpc."), "method names must not start with rpc.")
    }

    for b in Broadcast_Name {
        testing.expect(
            t,
            !strings.has_prefix(broadcast_name_wire[b], "rpc."),
            "notification names must not start with rpc.",
        )
    }
}

// Requests and notifications share one `method` namespace, so the two registries
// must never collide.
@(test)
test_method_and_notification_namespaces_are_disjoint :: proc(t: ^testing.T) {
    for m in Method_Name {
        for b in Broadcast_Name {
            testing.expect(
                t,
                method_name_wire[m] != broadcast_name_wire[b],
                "a method name must not also be a notification name",
            )
        }
    }
}

// Wire error numbers are the durable identity of an Error_Code. Each is distinct and
// is either one of JSON-RPC's reserved codes (which ACP reuses unchanged) or in the
// domain block; none may fall inside the spec-reserved range, LSP's block, or any
// code ACP claims, so no number means two different things across protocols.
@(test)
test_error_code_numbers_never_collide_across_protocols :: proc(t: ^testing.T) {
    jsonrpc_reserved := []i32{-32600, -32601, -32602, -32603}
    for a in Error_Code {
        n := error_code_number[a]
        is_reserved := false
        for r in jsonrpc_reserved {
            if n == r {
                is_reserved = true
            }
        }

        if !is_reserved {
            // Outside the block JSON-RPC reserves for pre-defined errors.
            testing.expect(t, n < -32768 || n > -32000, "a domain code must not sit in -32768..-32000")

            // Clear of the block LSP took in application space.
            testing.expect(t, n < -32899 || n > -32800, "a domain code must not sit in LSP's -32899..-32800")
        }

        for acp in ACP_RESERVED {
            testing.expect(t, n != acp, "a code ACP assigns must not be reused here")
        }

        for b in Error_Code {
            if a != b {
                testing.expect(t, n != error_code_number[b], "error numbers must be distinct")
            }
        }
    }
}
