package provider

import "base:runtime"
import "core:encoding/json"
import "libs:bindings/curl"

// Why a turn failed. Plain enum, `wire.Validation_Error` house style: the
// retry-after hint that accompanies `.Rate_Limited` is a field on the turn, not
// a payload here.
Transport_Error :: enum {
    // No failure.
    None,

    // The request was rejected as malformed or unsupported; retrying it
    // unchanged cannot help.
    Invalid_Request,

    // Credential missing, rejected, or not entitled (401/403).
    Authentication_Failed,

    // Throttled (429) and expected to succeed later.
    Rate_Limited,

    // Credit or plan allowance exhausted (429 with a quota error type).
    // Terminal: waiting does not help.
    Quota_Exhausted,

    // Provider-side failure (5xx).
    Server_Error,

    // Connection, DNS, TLS, or mid-transfer I/O failure.
    Network_Error,

    // Response bytes did not decode as the protocol requires.
    Parse_Error,

    // Connect timeout, idle-gap timeout, or a status the provider uses for one.
    Timed_Out,

    // Response carried a `Content-Encoding` the transport does not decode; it
    // requests none.
    Unsupported_Content_Encoding,

    // Stream ended before its protocol terminator, so the answer is partial.
    Stream_Truncated,

    // Response exceeded the transport's size bound.
    Response_Too_Large,

    // More than `MAX_TOOL_CALLS` tool calls in one turn.
    Too_Many_Tool_Calls,

    // One tool call's arguments exceeded `MAX_TOOL_CALL_BYTES`.
    Tool_Call_Too_Large,

    // Local allocation or transport resources were exhausted. Terminal: an
    // identical retry under the same pressure is not a recovery strategy.
    Resource_Exhausted,

    // Ended by our own side.
    Canceled,
}

// Error types that mean the account is out of allowance rather than merely
// throttled. Matched against the `error.type` / `error.code` of a 429 body.
@(rodata)
QUOTA_ERROR_TYPES := [?]string{"insufficient_quota", "usage_limit_reached", "usage_not_included"}

// Transport error for an HTTP status, given as much of the response body as the
// transport buffered. Both arguments are peer-supplied and never asserted on;
// `allocator` is scratch for parsing a 429 body and must be a bulk-reclaimable
// scope, since a malformed body can leave a partial allocation reclaimable only
// in bulk.
//
// 429 is the only status whose body matters. 1xx and 3xx are not expected on a
// streaming POST we build ourselves, so they fail rather than being retried.
transport_error_from_status :: proc(status: int, body: string, allocator: runtime.Allocator) -> Transport_Error {
    switch {
    case status >= 200 && status < 300:
        return .None

    case status == 401, status == 403:
        return .Authentication_Failed

    case status == 429:
        exhausted, err := body_is_quota_exhausted(body, allocator)
        if err != .None {
            return err
        }

        return exhausted ? .Quota_Exhausted : .Rate_Limited

    case status == 408, status == 425:
        return .Timed_Out

    case status >= 400 && status < 500:
        return .Invalid_Request

    case status >= 500 && status < 600:
        return .Server_Error

    case:
        return .Invalid_Request
    }
}

// Does an error body name one of the quota error types? An unparseable body is
// not a quota failure, so it costs a retry rather than a wrongly terminal turn.
// `allocator` is scratch and must be a bulk-reclaimable scope; a malformed body
// can leave a partial allocation reclaimable only in bulk.
@(private)
body_is_quota_exhausted :: proc(
    body: string,
    allocator: runtime.Allocator,
) -> (
    exhausted: bool,
    err: Transport_Error,
) {
    if len(body) == 0 {
        return false, .None
    }

    value, parse_err := json.parse_string(body, json.DEFAULT_SPECIFICATION, false, allocator)
    if parse_err != nil {
        if parse_err == .Out_Of_Memory {
            return false, .Resource_Exhausted
        }

        return false, .None
    }
    defer json.destroy_value(value, allocator)

    root, root_ok := value.(json.Object)
    if !root_ok {
        return false, .None
    }

    if nested, nested_ok := root["error"]; nested_ok {
        if obj, obj_ok := nested.(json.Object); obj_ok {
            nested_exhausted, found := quota_discriminator(obj)
            if found {
                return nested_exhausted, .None
            }
        }
    }

    exhausted, _ = quota_discriminator(root)
    return exhausted, .None
}

// Classify an object's string `type` / `code` fields. `found` distinguishes a
// non-quota discriminator from no discriminator, which is what lets a nested
// `error` object win over the top-level fallback.
@(private)
quota_discriminator :: proc(scope: json.Object) -> (exhausted, found: bool) {
    for key in ([?]string{"type", "code"}) {
        field, field_ok := scope[key]
        if !field_ok {
            continue
        }

        text, text_ok := field.(json.String)
        if !text_ok {
            continue
        }

        found = true
        for quota in QUOTA_ERROR_TYPES {
            if text == quota {
                return true, true
            }
        }
    }

    return false, found
}

// Transport error for the `curl.Code` of a completed transfer. Exhaustive: a
// code libcurl gains later must be classified here rather than bucketed.
//
// `.Write_Error` is our own body callback returning false, which only happens
// to abort a turn, so it joins `.Aborted_By_Callback` under `.Canceled`.
transport_error_from_curl :: proc(code: curl.Code) -> Transport_Error {
    switch code {
    case .Ok:
        return .None

    case .Couldnt_Resolve_Proxy,
         .Couldnt_Resolve_Host,
         .Couldnt_Connect,
         .Weird_Server_Reply,
         .Send_Error,
         .Recv_Error,
         .Send_Fail_Rewind,
         .Ssl_Connect_Error,
         .Ssl_Engine_Notfound,
         .Ssl_Engine_Setfailed,
         .Ssl_Engine_Initfailed,
         .Ssl_Certproblem,
         .Ssl_Cipher,
         .Ssl_Cacert_Badfile,
         .Ssl_Crl_Badfile,
         .Ssl_Issuer_Error,
         .Ssl_Shutdown_Failed,
         .Ssl_Pinnedpubkeynotmatch,
         .Ssl_Invalidcertstatus,
         .Ssl_Clientcert,
         .Peer_Failed_Verification,
         .Use_Ssl_Failed,
         .Http2,
         .Http2_Stream,
         .Http3,
         .Quic_Connect_Error,
         .Proxy,
         .No_Connection_Available,
         .Again,
         .Unrecoverable_Poll:
        return .Network_Error

    case .Out_Of_Memory:
        return .Resource_Exhausted

    case .Operation_Timedout:
        return .Timed_Out

    case .Partial_File, .Got_Nothing:
        return .Stream_Truncated

    case .Write_Error, .Aborted_By_Callback:
        return .Canceled

    case .Bad_Content_Encoding:
        return .Unsupported_Content_Encoding

    case .Filesize_Exceeded:
        return .Response_Too_Large

    case .Login_Denied, .Auth_Error, .Remote_Access_Denied:
        return .Authentication_Failed

    case .Http_Returned_Error:
        return .Server_Error

    case .Unsupported_Protocol,
         .Failed_Init,
         .Url_Malformat,
         .Not_Built_In,
         .Quote_Error,
         .Upload_Failed,
         .Read_Error,
         .Range_Error,
         .Http_Post_Error,
         .Bad_Download_Resume,
         .Function_Not_Found,
         .Bad_Function_Argument,
         .Interface_Failed,
         .Too_Many_Redirects,
         .Unknown_Option,
         .Setopt_Option_Syntax,
         .Chunk_Failed,
         .Recursive_Api_Call,
         .Remote_Disk_Full,
         .Remote_File_Exists,
         .Remote_File_Not_Found,
         .File_Couldnt_Read_File,
         .Ftp_Accept_Failed,
         .Ftp_Weird_Pass_Reply,
         .Ftp_Accept_Timeout,
         .Ftp_Weird_Pasv_Reply,
         .Ftp_Weird_227_Format,
         .Ftp_Cant_Get_Host,
         .Ftp_Couldnt_Set_Type,
         .Ftp_Couldnt_Retr_File,
         .Ftp_Port_Failed,
         .Ftp_Couldnt_Use_Rest,
         .Ftp_Pret_Failed,
         .Ftp_Bad_File_List,
         .Tftp_Notfound,
         .Tftp_Perm,
         .Tftp_Illegal,
         .Tftp_Unknownid,
         .Tftp_Nosuchuser,
         .Ldap_Cannot_Bind,
         .Ldap_Search_Failed,
         .Rtsp_Cseq_Error,
         .Rtsp_Session_Error,
         .Ssh,
         .Obsolete20,
         .Obsolete24,
         .Obsolete29,
         .Obsolete32,
         .Obsolete40,
         .Obsolete44,
         .Obsolete46,
         .Obsolete50,
         .Obsolete51,
         .Obsolete57,
         .Obsolete62,
         .Obsolete75,
         .Obsolete76:
        return .Invalid_Request
    }

    // Deliberately not an assertion: a libcurl newer than this enum may return
    // a value outside it, and version skew must fail the turn, not the daemon.
    return .Network_Error
}
