package http

import "core:strings"

// Errors in the request-framing subset accepted by the nbio driver.
Request_Error :: enum {
    None,
    Invalid_Content_Length,
    Unsupported_Transfer_Coding,
    Unsupported_Expectation,
}

// Framing for a route that MAY carry a Content-Length body. Transfer codings and
// expectations are rejected outright; a valid decimal
// Content-Length yields its value, and an absent one is a zero-length body. An empty,
// non-digit, overflowing, or duplicated length is `Invalid_Content_Length`. The caller
// enforces any route-specific size cap on the returned length.
validate_body :: proc(head: Request_Head) -> (length: i64, err: Request_Error) {
    if _, lookup := request_header(head, "transfer-encoding"); lookup != .Missing {
        return 0, .Unsupported_Transfer_Coding
    }

    if _, lookup := request_header(head, "expect"); lookup != .Missing {
        return 0, .Unsupported_Expectation
    }

    content_length, lookup := request_header(head, "content-length")
    switch lookup {
    case .Missing:
        return 0, .None

    case .Duplicate:
        return 0, .Invalid_Content_Length

    case .One:
        if len(content_length) == 0 {
            return 0, .Invalid_Content_Length
        }

        value: i64
        for i in 0 ..< len(content_length) {
            c := content_length[i]
            if c < '0' || c > '9' {
                return 0, .Invalid_Content_Length
            }

            digit := i64(c - '0')
            if value > (max(i64) - digit) / 10 {
                return 0, .Invalid_Content_Length
            }

            value = value * 10 + digit
        }

        return value, .None
    }

    return 0, .Invalid_Content_Length
}

// Split a validated origin-form target into path and raw query.
split_target :: proc(target: string) -> (path: string, query: string) {
    assert(origin_target_valid(target), "split_target needs a validated origin-form target")

    mark := strings.index_byte(target, '?')
    if mark < 0 {
        return target, ""
    }

    return target[:mark], target[mark + 1:]
}

// Find one raw query value without decoding or silently choosing among duplicates.
// Parameters without `=` have an empty value and still count as present.
query_value :: proc(query: string, name: string) -> (value: string, lookup: Lookup) {
    assert(len(name) > 0, "query_value needs a non-empty name")
    assert(strings.index_byte(name, '&') < 0 && strings.index_byte(name, '=') < 0, "query name contains a separator")

    rest := query
    for len(rest) > 0 {
        pair := rest
        if amp := strings.index_byte(rest, '&'); amp >= 0 {
            pair = rest[:amp]
            rest = rest[amp + 1:]
        } else {
            rest = ""
        }

        key := pair
        candidate := ""
        if eq := strings.index_byte(pair, '='); eq >= 0 {
            key = pair[:eq]
            candidate = pair[eq + 1:]
        }

        if key == name {
            if lookup == .One {
                return "", .Duplicate
            }

            value = candidate
            lookup = .One
        }
    }

    return value, lookup
}
