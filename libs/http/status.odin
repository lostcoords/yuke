package http

// RFC 9110 §15 in full, plus RFC 6585 (428, 429, 431, 511) and RFC 7725 (451). Phrases
// follow RFC 9110, which renamed 413 to "Content Too Large" and 422 to "Unprocessable
// Content". 305 is deprecated; 306 and 418 are unassigned, so neither has a value.
Status :: enum {
    // 1xx informational
    Continue,
    Switching_Protocols,
    // 2xx successful
    Ok,
    Created,
    Accepted,
    Non_Authoritative_Information,
    No_Content,
    Reset_Content,
    Partial_Content,
    // 3xx redirection
    Multiple_Choices,
    Moved_Permanently,
    Found,
    See_Other,
    Not_Modified,
    Use_Proxy,
    Temporary_Redirect,
    Permanent_Redirect,
    // 4xx client error
    Bad_Request,
    Unauthorized,
    Payment_Required,
    Forbidden,
    Not_Found,
    Method_Not_Allowed,
    Not_Acceptable,
    Proxy_Authentication_Required,
    Request_Timeout,
    Conflict,
    Gone,
    Length_Required,
    Precondition_Failed,
    Content_Too_Large,
    Uri_Too_Long,
    Unsupported_Media_Type,
    Range_Not_Satisfiable,
    Expectation_Failed,
    Misdirected_Request,
    Unprocessable_Content,
    Upgrade_Required,
    Precondition_Required,
    Too_Many_Requests,
    Request_Header_Fields_Too_Large,
    Unavailable_For_Legal_Reasons,
    // 5xx server error
    Internal_Server_Error,
    Not_Implemented,
    Bad_Gateway,
    Service_Unavailable,
    Gateway_Timeout,
    Http_Version_Not_Supported,
    Network_Authentication_Required,
}

// Status line values indexed by `Status`; the tests prove it total and ordered.
@(rodata)
status_wire := [Status]string {
    .Continue                        = "100 Continue",
    .Switching_Protocols             = "101 Switching Protocols",
    .Ok                              = "200 OK",
    .Created                         = "201 Created",
    .Accepted                        = "202 Accepted",
    .Non_Authoritative_Information   = "203 Non-Authoritative Information",
    .No_Content                      = "204 No Content",
    .Reset_Content                   = "205 Reset Content",
    .Partial_Content                 = "206 Partial Content",
    .Multiple_Choices                = "300 Multiple Choices",
    .Moved_Permanently               = "301 Moved Permanently",
    .Found                           = "302 Found",
    .See_Other                       = "303 See Other",
    .Not_Modified                    = "304 Not Modified",
    .Use_Proxy                       = "305 Use Proxy",
    .Temporary_Redirect              = "307 Temporary Redirect",
    .Permanent_Redirect              = "308 Permanent Redirect",
    .Bad_Request                     = "400 Bad Request",
    .Unauthorized                    = "401 Unauthorized",
    .Payment_Required                = "402 Payment Required",
    .Forbidden                       = "403 Forbidden",
    .Not_Found                       = "404 Not Found",
    .Method_Not_Allowed              = "405 Method Not Allowed",
    .Not_Acceptable                  = "406 Not Acceptable",
    .Proxy_Authentication_Required   = "407 Proxy Authentication Required",
    .Request_Timeout                 = "408 Request Timeout",
    .Conflict                        = "409 Conflict",
    .Gone                            = "410 Gone",
    .Length_Required                 = "411 Length Required",
    .Precondition_Failed             = "412 Precondition Failed",
    .Content_Too_Large               = "413 Content Too Large",
    .Uri_Too_Long                    = "414 URI Too Long",
    .Unsupported_Media_Type          = "415 Unsupported Media Type",
    .Range_Not_Satisfiable           = "416 Range Not Satisfiable",
    .Expectation_Failed              = "417 Expectation Failed",
    .Misdirected_Request             = "421 Misdirected Request",
    .Unprocessable_Content           = "422 Unprocessable Content",
    .Upgrade_Required                = "426 Upgrade Required",
    .Precondition_Required           = "428 Precondition Required",
    .Too_Many_Requests               = "429 Too Many Requests",
    .Request_Header_Fields_Too_Large = "431 Request Header Fields Too Large",
    .Unavailable_For_Legal_Reasons   = "451 Unavailable For Legal Reasons",
    .Internal_Server_Error           = "500 Internal Server Error",
    .Not_Implemented                 = "501 Not Implemented",
    .Bad_Gateway                     = "502 Bad Gateway",
    .Service_Unavailable             = "503 Service Unavailable",
    .Gateway_Timeout                 = "504 Gateway Timeout",
    .Http_Version_Not_Supported      = "505 HTTP Version Not Supported",
    .Network_Authentication_Required = "511 Network Authentication Required",
}

status_line :: proc(status: Status) -> string {
    return status_wire[status]
}

// Redirects carrying a `Location` (RFC 9110 §15.4); 304 and 305 do not qualify.
status_is_redirect :: proc(status: Status) -> bool {
    #partial switch status {
    case .Multiple_Choices, .Moved_Permanently, .Found, .See_Other, .Temporary_Redirect, .Permanent_Redirect:
        return true
    }

    return false
}
