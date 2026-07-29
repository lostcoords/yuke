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

// Split a `Host` field value into its bare host, dropping an optional `:port` and an
// IP-literal's brackets (RFC 3986 §3.2.2). `bracketed` reports whether the host arrived
// in brackets, which only an IP-literal may be.
//
// Hand-rolled because `net.split_port` assumes a leading `[` on seeing `]:` and slices
// `[1:0]` on a peer-supplied `]:80`; `net.parse_address` panics the same way. Any caller
// that touches a peer `Host` needs this, so it lives beside the other split helpers.
split_host :: proc(host: string) -> (name: string, bracketed: bool, ok: bool) {
    if len(host) == 0 {
        return "", false, false
    }

    if host[0] == '[' {
        bracketed = true

        close := strings.index_byte(host, ']')
        if close < 0 {
            return "", bracketed, false
        }

        if rest := host[close + 1:]; len(rest) > 0 && !host_port_valid(rest) {
            return "", bracketed, false
        }

        name = host[1:close]
    } else {
        // A `]` outside a literal is illegal here, and is the shape that panics.
        if strings.index_byte(host, ']') >= 0 {
            return "", bracketed, false
        }

        colon := strings.index_byte(host, ':')
        if colon < 0 {
            name = host
        } else {
            if !host_port_valid(host[colon:]) {
                return "", bracketed, false
            }

            name = host[:colon]
        }
    }

    return name, bracketed, len(name) > 0
}

// Whether an authority's suffix is a `:port`: a colon then digits. RFC 3986 §3.2.3
// permits an empty port, so a bare `:` is valid.
@(private)
host_port_valid :: proc(port: string) -> bool {
    if len(port) == 0 || port[0] != ':' {
        return false
    }

    for i in 1 ..< len(port) {
        if port[i] < '0' || port[i] > '9' {
            return false
        }
    }

    return true
}

// Find one raw query value without decoding or silently choosing among duplicates.
// Parameters without `=` have an empty value and still count as present.
query_value :: proc(query: string, name: string) -> (value: string, lookup: Lookup) {
    assert(len(name) > 0, "query_value needs a non-empty name")
    assert(strings.index_byte(name, '&') < 0, "query name contains '&'")
    assert(strings.index_byte(name, '=') < 0, "query name contains '='")

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
