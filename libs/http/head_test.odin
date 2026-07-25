package http

import "core:testing"

@(test)
test_request_head_is_strict_and_borrowed :: proc(t: ^testing.T) {
    request := "GET /a/b?c=d HTTP/1.1\r\nhost: example.test\r\nauthorization:\tBearer tok \r\n\r\n!"
    head, status, err := parse_request_head(transmute([]byte)request)

    testing.expect_value(t, status, Head_Status.Ready)
    testing.expect_value(t, err, Head_Error.None)
    testing.expect_value(t, head.method, "GET")
    testing.expect_value(t, head.target, "/a/b?c=d")
    testing.expect_value(t, head.consumed, len(request) - 1)

    value, lookup := request_header(head, "Authorization")
    testing.expect_value(t, lookup, Lookup.One)
    testing.expect_value(t, value, "Bearer tok")
}

@(test)
test_request_head_rejects_ambiguous_or_invalid_input :: proc(t: ^testing.T) {
    cases := []struct {
        request: string,
        err:     Head_Error,
    } {
        {"GET / HTTP/1.0\r\nhost: x\r\n\r\n", .Unsupported_Version},
        {"GET x HTTP/1.1\r\nhost: x\r\n\r\n", .Unsupported_Target},
        {"GET /bad%2 HTTP/1.1\r\nhost: x\r\n\r\n", .Unsupported_Target},
        {"GET / HTTP/1.1\r\n\r\n", .Missing_Host},
        {"GET / HTTP/1.1\r\nhost: x\r\nhost: y\r\n\r\n", .Duplicate_Host},
        {"GET / HTTP/1.1\r\n host: x\r\n\r\n", .Bad_Header},
        {"GET  / HTTP/1.1\r\nhost: x\r\n\r\n", .Bad_Start_Line},
    }

    for test_case in cases {
        head, status, err := parse_request_head(transmute([]byte)test_case.request)
        testing.expect_value(t, status, Head_Status.Ready)
        testing.expect_value(t, err, test_case.err)
        testing.expect_value(t, head.consumed, len(test_case.request))
        testing.expect_value(t, len(head.bytes), len(test_case.request))
    }
}

@(test)
test_request_head_reports_need_more :: proc(t: ^testing.T) {
    _, status, err := parse_request_head(transmute([]byte)string("GET / HTTP/1.1\r\nhost: x\r\n"))

    testing.expect_value(t, status, Head_Status.Need_More)
    testing.expect_value(t, err, Head_Error.None)
}

@(test)
test_body_framing_reports_the_content_length :: proc(t: ^testing.T) {
    cases := []struct {
        request: string,
        length:  i64,
        err:     Request_Error,
    } {
        {"PUT / HTTP/1.1\r\nhost: x\r\n\r\n", 0, .None},
        {"PUT / HTTP/1.1\r\nhost: x\r\ncontent-length: 0\r\n\r\n", 0, .None},
        {"PUT / HTTP/1.1\r\nhost: x\r\ncontent-length: 10\r\n\r\n", 10, .None},
        {"PUT / HTTP/1.1\r\nhost: x\r\ncontent-length: 067108864\r\n\r\n", 67108864, .None},
        {"PUT / HTTP/1.1\r\nhost: x\r\ncontent-length: \r\n\r\n", 0, .Invalid_Content_Length},
        {"PUT / HTTP/1.1\r\nhost: x\r\ncontent-length: nope\r\n\r\n", 0, .Invalid_Content_Length},
        {"PUT / HTTP/1.1\r\nhost: x\r\ncontent-length: 12345678901234567890\r\n\r\n", 0, .Invalid_Content_Length},
        {"PUT / HTTP/1.1\r\nhost: x\r\ncontent-length: 1\r\ncontent-length: 1\r\n\r\n", 0, .Invalid_Content_Length},
        {"PUT / HTTP/1.1\r\nhost: x\r\ntransfer-encoding: chunked\r\n\r\n", 0, .Unsupported_Transfer_Coding},
        {"PUT / HTTP/1.1\r\nhost: x\r\nexpect: 100-continue\r\n\r\n", 0, .Unsupported_Expectation},
    }

    for test_case in cases {
        head, _, head_err := parse_request_head(transmute([]byte)test_case.request)
        testing.expect_value(t, head_err, Head_Error.None)

        length, err := validate_body(head)
        testing.expect_value(t, err, test_case.err)
        testing.expect_value(t, length, test_case.length)
    }
}

@(test)
test_response_head_requires_the_status_separator :: proc(t: ^testing.T) {
    valid := "HTTP/1.1 101 \r\nupgrade: websocket\r\n\r\n"
    head, status, err := parse_response_head(transmute([]byte)valid)
    testing.expect_value(t, status, Head_Status.Ready)
    testing.expect_value(t, err, Head_Error.None)
    testing.expect_value(t, head.status_code, 101)

    invalid := "HTTP/1.1 101\r\nupgrade: websocket\r\n\r\n"
    head, status, err = parse_response_head(transmute([]byte)invalid)
    testing.expect_value(t, status, Head_Status.Ready)
    testing.expect_value(t, err, Head_Error.Bad_Start_Line)
    testing.expect_value(t, head.consumed, len(invalid))
}

@(test)
test_query_lookup_rejects_duplicates :: proc(t: ^testing.T) {
    path, query := split_target("/ws?token=abc&x=1")
    testing.expect_value(t, path, "/ws")
    testing.expect_value(t, query, "token=abc&x=1")

    value, lookup := query_value(query, "token")
    testing.expect_value(t, lookup, Lookup.One)
    testing.expect_value(t, value, "abc")

    _, lookup = query_value("token=a&token=b", "token")
    testing.expect_value(t, lookup, Lookup.Duplicate)
}
