package http

import "core:strings"

// Whether a complete HTTP head is available in the supplied buffer.
Head_Status :: enum {
    Ready,
    Need_More,
}

// Syntax and protocol errors returned for a complete HTTP head.
Head_Error :: enum {
    None,
    Bad_Start_Line,
    Bad_Header,
    Missing_Host,
    Duplicate_Host,
    Unsupported_Version,
    Unsupported_Target,
}

// Result of looking up a field in a validated head.
Lookup :: enum {
    Missing,
    One,
    Duplicate,
}

// One validated HTTP field. Both strings borrow the parsed head buffer.
Header :: struct {
    name:  string,
    value: string,
}

// Iterator over the validated field block of a parsed head.
Header_Iterator :: struct {
    // @private
    rest: string,
}

// A validated HTTP/1.1 request head. All slices borrow `bytes`.
Request_Head :: struct {
    method:   string,
    target:   string,
    fields:   string,
    bytes:    []byte,
    consumed: int,
}

// A validated HTTP/1.1 response head. All slices borrow `bytes`.
Response_Head :: struct {
    status_code: int,
    fields:      string,
    bytes:       []byte,
    consumed:    int,
}

// Parse and validate one HTTP/1.1 request head. A complete request must use the
// origin form and contain exactly one non-empty Host field.
parse_request_head :: proc(buf: []byte) -> (head: Request_Head, status: Head_Status, err: Head_Error) {
    end := strings.index(string(buf), "\r\n\r\n")
    if end < 0 do return {}, .Need_More, .None

    consumed := end + 4
    head.bytes = buf[:consumed]
    head.consumed = consumed
    block := string(buf[:end + 2])
    line, fields, has_line := split_start_line(block)
    if !has_line do return head, .Ready, .Bad_Start_Line

    method, target, line_err := parse_request_line(line)
    if line_err != .None do return head, .Ready, line_err

    if !fields_valid(fields) do return head, .Ready, .Bad_Header

    value, lookup := header_lookup(fields, "host")
    switch lookup {
    case .Missing:
        return head, .Ready, .Missing_Host

    case .Duplicate:
        return head, .Ready, .Duplicate_Host

    case .One:
        if len(value) == 0 do return head, .Ready, .Missing_Host
    }

    head = Request_Head {
        method   = method,
        target   = target,
        fields   = fields,
        bytes    = buf[:consumed],
        consumed = consumed,
    }

    return head, .Ready, .None
}

// Parse and validate one HTTP/1.1 response head.
parse_response_head :: proc(buf: []byte) -> (head: Response_Head, status: Head_Status, err: Head_Error) {
    end := strings.index(string(buf), "\r\n\r\n")
    if end < 0 do return {}, .Need_More, .None

    consumed := end + 4
    head.bytes = buf[:consumed]
    head.consumed = consumed
    block := string(buf[:end + 2])
    line, fields, has_line := split_start_line(block)
    if !has_line do return head, .Ready, .Bad_Start_Line

    status_code, line_err := parse_status_line(line)
    if line_err != .None do return head, .Ready, line_err

    if !fields_valid(fields) do return head, .Ready, .Bad_Header

    head = Response_Head {
        status_code = status_code,
        fields      = fields,
        bytes       = buf[:consumed],
        consumed    = consumed,
    }

    return head, .Ready, .None
}

// Begin iterating a validated field block.
headers :: proc(fields: string) -> Header_Iterator {
    return {rest = fields}
}

// Return the next field. Values have optional whitespace removed at both ends.
header_next :: proc(it: ^Header_Iterator) -> (header: Header, ok: bool) {
    assert(it != nil, "header_next needs an iterator")

    if len(it.rest) == 0 do return {}, false

    line: string
    line, it.rest = take_line(it.rest)
    colon := strings.index_byte(line, ':')
    assert(colon > 0, "validated header iterator found a malformed field")

    return {name = line[:colon], value = trim_ows(line[colon + 1:])}, true
}

// Look up a request field case-insensitively without accepting ambiguity.
request_header :: proc(head: Request_Head, name: string) -> (value: string, lookup: Lookup) {
    assert(field_name_valid(name), "request_header needs a valid field name")

    return header_lookup(head.fields, name)
}

// Look up a response field case-insensitively without accepting ambiguity.
response_header :: proc(head: Response_Head, name: string) -> (value: string, lookup: Lookup) {
    assert(field_name_valid(name), "response_header needs a valid field name")

    return header_lookup(head.fields, name)
}

// Whether `name` is an HTTP token and can be emitted as a field name.
field_name_valid :: proc(name: string) -> bool {
    if len(name) == 0 do return false

    for i in 0 ..< len(name) {
        if !token_byte(name[i]) do return false
    }

    return true
}

// Whether `value` is safe to emit as one field value. CR, LF, NUL, and other
// controls are rejected; horizontal tab is the sole permitted control byte.
field_value_valid :: proc(value: string) -> bool {
    for i in 0 ..< len(value) {
        c := value[i]
        if c < 0x20 && c != '\t' || c == 0x7f do return false
    }

    return true
}

// Whether `target` is in the supported origin form and safe to emit verbatim.
request_target_valid :: proc(target: string) -> bool {
    return origin_target_valid(target)
}

// Parse a request-line into method and target, accepting only `HTTP/1.1` and the
// origin-form target. Each violation maps to a specific `Head_Error`.
parse_request_line :: proc(line: string) -> (method: string, target: string, err: Head_Error) {
    first := strings.index_byte(line, ' ')
    if first <= 0 do return "", "", .Bad_Start_Line

    rest := line[first + 1:]
    second := strings.index_byte(rest, ' ')
    if second <= 0 || strings.index_byte(rest[second + 1:], ' ') >= 0 do return "", "", .Bad_Start_Line

    method = line[:first]
    target = rest[:second]
    version := rest[second + 1:]
    if !field_name_valid(method) do return "", "", .Bad_Start_Line

    if version != "HTTP/1.1" do return "", "", .Unsupported_Version

    if !origin_target_valid(target) do return "", "", .Unsupported_Target

    return method, target, .None
}

// Parse a status-line into a numeric code, requiring `HTTP/1.1` and the trailing
// SP after the 3-digit code. The reason phrase is validated as a field value.
parse_status_line :: proc(line: string) -> (status_code: int, err: Head_Error) {
    if len(line) < len("HTTP/1.1 000 ") || line[:len("HTTP/1.1 ")] != "HTTP/1.1 " do return 0, .Bad_Start_Line

    code := line[len("HTTP/1.1 "):len("HTTP/1.1 000")]
    for i in 0 ..< len(code) {
        c := code[i]
        if c < '0' || c > '9' do return 0, .Bad_Start_Line
    }

    if line[len("HTTP/1.1 000")] != ' ' do return 0, .Bad_Start_Line

    if !field_value_valid(line[len("HTTP/1.1 000 "):]) do return 0, .Bad_Start_Line

    status_code = int(code[0] - '0') * 100 + int(code[1] - '0') * 10 + int(code[2] - '0')

    return status_code, .None
}

// Split a head block into its request/status-line and the field block. The field
// block retains each line's own `CRLF` and excludes the blank terminator line.
split_start_line :: proc(block: string) -> (line: string, fields: string, ok: bool) {
    line_end := strings.index(block, "\r\n")
    if line_end < 0 do return "", "", false

    line = block[:line_end]
    if line_end + 2 < len(block) do fields = block[line_end + 2:]

    return line, fields, true
}

// Whether every field line is a syntactically valid `name: value`. Structural
// only: duplicate fields are permitted here, since uniqueness is a per-field
// semantic enforced at lookup (notably `Host`).
fields_valid :: proc(fields: string) -> bool {
    it := Header_Iterator {
        rest = fields,
    }
    for len(it.rest) > 0 {
        line: string
        line, it.rest = take_line(it.rest)
        colon := strings.index_byte(line, ':')
        if colon <= 0 || !field_name_valid(line[:colon]) || !field_value_valid(line[colon + 1:]) do return false
    }

    return true
}

// Find a field case-insensitively, returning `.Duplicate` instead of silently
// choosing among repeats. The value borrows the field block and has surrounding
// OWS removed.
header_lookup :: proc(fields: string, name: string) -> (value: string, lookup: Lookup) {
    it := headers(fields)
    for {
        field, ok := header_next(&it)
        if !ok do break

        if strings.equal_fold(field.name, name) {
            if lookup == .One do return "", .Duplicate

            value = field.value
            lookup = .One
        }
    }

    return value, lookup
}

take_line :: proc(s: string) -> (line: string, rest: string) {
    idx := strings.index(s, "\r\n")
    if idx < 0 do return s, ""

    return s[:idx], s[idx + 2:]
}

trim_ows :: proc(value: string) -> string {
    first := 0
    for first < len(value) && (value[first] == ' ' || value[first] == '\t') {
        first += 1
    }

    last := len(value)
    for last > first && (value[last - 1] == ' ' || value[last - 1] == '\t') {
        last -= 1
    }

    return value[first:last]
}

token_byte :: proc(c: byte) -> bool {
    switch c {
    case '0' ..= '9', 'A' ..= 'Z', 'a' ..= 'z':
        return true

    case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
        return true
    }

    return false
}

// Whether `target` is in RFC 7230 origin form (a path beginning with `/`), with
// only permitted URI bytes and well-formed percent-encoding. Absolute-URI,
// authority, and asterisk forms are rejected.
origin_target_valid :: proc(target: string) -> bool {
    if len(target) == 0 || target[0] != '/' do return false

    for i := 0; i < len(target); i += 1 {
        c := target[i]
        switch {
        case c == '%':
            if i + 2 >= len(target) || !hex_byte(target[i + 1]) || !hex_byte(target[i + 2]) do return false

            i += 2

        case uri_byte(c):

        case:
            return false
        }
    }

    return true
}

uri_byte :: proc(c: byte) -> bool {
    switch c {
    case '0' ..= '9', 'A' ..= 'Z', 'a' ..= 'z':
        return true

    case '-', '.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':', '@', '/', '?':
        return true
    }

    return false
}

hex_byte :: proc(c: byte) -> bool {
    return c >= '0' && c <= '9' || c >= 'A' && c <= 'F' || c >= 'a' && c <= 'f'
}
