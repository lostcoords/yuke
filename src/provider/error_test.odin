package provider

import "core:testing"
import "libs:bindings/curl"
import ts "libs:testsupport"

@(test)
test_status_mapping :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    Case :: struct {
        status: int,
        want:   Transport_Error,
    }

    cases := [?]Case {
        {200, .None},
        {201, .None},
        {299, .None},
        {400, .Invalid_Request},
        {401, .Authentication_Failed},
        {403, .Authentication_Failed},
        {404, .Invalid_Request},
        {408, .Timed_Out},
        {413, .Invalid_Request},
        {422, .Invalid_Request},
        {425, .Timed_Out},
        {499, .Invalid_Request},
        {500, .Server_Error},
        {502, .Server_Error},
        {529, .Server_Error},
        {599, .Server_Error},
        // Never expected on a streaming POST we build ourselves.
        {0, .Invalid_Request},
        {100, .Invalid_Request},
        {302, .Invalid_Request},
        {600, .Invalid_Request},
    }

    for c in cases {
        got := transport_error_from_status(c.status, "", context.temp_allocator)
        testing.expectf(t, got == c.want, "status %d must map to %v, got %v", c.status, c.want, got)
    }
}

// A quota error type on a 429 is terminal; anything else is a throttle.
@(test)
test_status_429_body_classification :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    Case :: struct {
        body: string,
        want: Transport_Error,
    }

    cases := [?]Case {
        {`{"error":{"type":"insufficient_quota","message":"no credit"}}`, .Quota_Exhausted},
        {`{"error":{"type":"usage_limit_reached"}}`, .Quota_Exhausted},
        {`{"error":{"type":"usage_not_included"}}`, .Quota_Exhausted},
        {`{"error":{"code":"insufficient_quota"}}`, .Quota_Exhausted},
        {`{"type":"usage_limit_reached"}`, .Quota_Exhausted},
        // Top-level fields are a fallback when a nested object carries no
        // discriminator of its own.
        {`{"error":{"message":"no credit"},"type":"usage_limit_reached"}`, .Quota_Exhausted},
        {`{"error":{"type":"rate_limit_error","message":"slow down"}}`, .Rate_Limited},
        {`{"error":{"type":"overloaded_error"}}`, .Rate_Limited},
        // A nested discriminator is authoritative when top-level fields conflict.
        {`{"error":{"type":"rate_limit_error"},"type":"usage_limit_reached"}`, .Rate_Limited},
        // Right token, wrong place: a message is prose, not a classification.
        {`{"error":{"type":"rate_limit_error","message":"insufficient_quota"}}`, .Rate_Limited},
        // Non-string error types must not be coerced.
        {`{"error":{"type":429}}`, .Rate_Limited},
        {`{"error":"insufficient_quota"}`, .Rate_Limited},
        // Unparseable, truncated, empty, and non-object bodies all degrade to
        // the retryable side.
        {`{"error":{"type":"insufficient_quo`, .Rate_Limited},
        {"Too Many Requests", .Rate_Limited},
        {"", .Rate_Limited},
        {"[]", .Rate_Limited},
        {"{}", .Rate_Limited},
    }

    for c in cases {
        got := transport_error_from_status(429, c.body, context.temp_allocator)
        testing.expectf(t, got == c.want, "429 with body %q must map to %v, got %v", c.body, c.want, got)
    }
}

// The body is only consulted for 429.
@(test)
test_quota_body_ignored_on_other_statuses :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    body := `{"error":{"type":"insufficient_quota"}}`
    testing.expect_value(
        t,
        transport_error_from_status(400, body, context.temp_allocator),
        Transport_Error.Invalid_Request,
    )
    testing.expect_value(
        t,
        transport_error_from_status(500, body, context.temp_allocator),
        Transport_Error.Server_Error,
    )
}

@(test)
test_status_429_classification_surfaces_allocation_failure :: proc(t: ^testing.T) {
    failing: ts.Failing_Allocator
    ts.failing_allocator_init(&failing, context.allocator, 0)

    body := `{"error":{"type":"insufficient_quota"}}`
    got := transport_error_from_status(429, body, ts.failing_allocator(&failing))
    testing.expect_value(t, got, Transport_Error.Resource_Exhausted)
}

@(test)
test_curl_code_mapping :: proc(t: ^testing.T) {
    Case :: struct {
        code: curl.Code,
        want: Transport_Error,
    }

    cases := [?]Case {
        {.Ok, .None},
        {.Couldnt_Resolve_Host, .Network_Error},
        {.Couldnt_Connect, .Network_Error},
        {.Recv_Error, .Network_Error},
        {.Ssl_Connect_Error, .Network_Error},
        {.Peer_Failed_Verification, .Network_Error},
        {.Http2_Stream, .Network_Error},
        {.Out_Of_Memory, .Resource_Exhausted},
        {.Operation_Timedout, .Timed_Out},
        {.Partial_File, .Stream_Truncated},
        {.Got_Nothing, .Stream_Truncated},
        {.Write_Error, .Canceled},
        {.Aborted_By_Callback, .Canceled},
        {.Bad_Content_Encoding, .Unsupported_Content_Encoding},
        {.Filesize_Exceeded, .Response_Too_Large},
        {.Login_Denied, .Authentication_Failed},
        {.Auth_Error, .Authentication_Failed},
        {.Http_Returned_Error, .Server_Error},
        {.Url_Malformat, .Invalid_Request},
        {.Unknown_Option, .Invalid_Request},
        {.Unsupported_Protocol, .Invalid_Request},
    }

    for c in cases {
        got := transport_error_from_curl(c.code)
        testing.expectf(t, got == c.want, "curl code %v must map to %v, got %v", c.code, c.want, got)
    }
}

// Only `.Ok` may produce a success, and the low-speed idle timeout must not
// look like a cancellation.
@(test)
test_curl_code_mapping_is_total_and_never_spurious_success :: proc(t: ^testing.T) {
    for code in curl.Code {
        got := transport_error_from_curl(code)
        testing.expectf(t, (got == .None) == (code == .Ok), "only .Ok may map to .None, %v mapped to %v", code, got)
    }

    testing.expect_value(t, transport_error_from_curl(.Operation_Timedout), Transport_Error.Timed_Out)
}
