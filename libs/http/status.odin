package http

// Statuses emitted by the small nbio server and daemon front door.
Status :: enum {
    Ok,
    Created,
    Bad_Request,
    Unauthorized,
    Forbidden,
    Not_Found,
    Method_Not_Allowed,
    Request_Timeout,
    Payload_Too_Large,
    Expectation_Failed,
    Request_Header_Fields_Too_Large,
    Internal_Server_Error,
    Service_Unavailable,
}

// Status line values indexed by `Status`.
@(rodata)
status_wire := [Status]string {
    .Ok                              = "200 OK",
    .Created                         = "201 Created",
    .Bad_Request                     = "400 Bad Request",
    .Unauthorized                    = "401 Unauthorized",
    .Forbidden                       = "403 Forbidden",
    .Not_Found                       = "404 Not Found",
    .Method_Not_Allowed              = "405 Method Not Allowed",
    .Request_Timeout                 = "408 Request Timeout",
    .Payload_Too_Large               = "413 Payload Too Large",
    .Expectation_Failed              = "417 Expectation Failed",
    .Request_Header_Fields_Too_Large = "431 Request Header Fields Too Large",
    .Internal_Server_Error           = "500 Internal Server Error",
    .Service_Unavailable             = "503 Service Unavailable",
}

status_line :: proc(status: Status) -> string {
    return status_wire[status]
}
