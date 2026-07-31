package curl

import "core:c"

// Opaque easy handle (`CURL *`): one request/response. Never shared across threads.
Easy :: struct {}

// Opaque multi handle (`CURLM *`): drives many easy handles from one thread.
Multi :: struct {}

// Linked list of `Name: value` request header lines (`struct curl_slist *`).
// `slist_append` copies the string; the list itself is NOT copied by setopt and
// must outlive the transfer it is attached to.
Slist :: struct {
    data: cstring,
    next: ^Slist,
}

// Result codes from the easy interface (`CURLcode`). Kept complete so a code
// coming back from libcurl is always a valid enum value; callers discriminate
// with `#partial switch`.
Code :: enum c.int {
    Ok                       = 0,
    Unsupported_Protocol     = 1,
    Failed_Init              = 2,
    Url_Malformat            = 3,
    Not_Built_In             = 4,
    Couldnt_Resolve_Proxy    = 5,
    Couldnt_Resolve_Host     = 6,
    Couldnt_Connect          = 7,
    Weird_Server_Reply       = 8,
    Remote_Access_Denied     = 9,
    Ftp_Accept_Failed        = 10,
    Ftp_Weird_Pass_Reply     = 11,
    Ftp_Accept_Timeout       = 12,
    Ftp_Weird_Pasv_Reply     = 13,
    Ftp_Weird_227_Format     = 14,
    Ftp_Cant_Get_Host        = 15,
    Http2                    = 16,
    Ftp_Couldnt_Set_Type     = 17,
    Partial_File             = 18,
    Ftp_Couldnt_Retr_File    = 19,
    Obsolete20               = 20,
    Quote_Error              = 21,
    Http_Returned_Error      = 22,
    Write_Error              = 23,
    Obsolete24               = 24,
    Upload_Failed            = 25,
    Read_Error               = 26,
    Out_Of_Memory            = 27,
    Operation_Timedout       = 28,
    Obsolete29               = 29,
    Ftp_Port_Failed          = 30,
    Ftp_Couldnt_Use_Rest     = 31,
    Obsolete32               = 32,
    Range_Error              = 33,
    Http_Post_Error          = 34,
    Ssl_Connect_Error        = 35,
    Bad_Download_Resume      = 36,
    File_Couldnt_Read_File   = 37,
    Ldap_Cannot_Bind         = 38,
    Ldap_Search_Failed       = 39,
    Obsolete40               = 40,
    Function_Not_Found       = 41,
    Aborted_By_Callback      = 42,
    Bad_Function_Argument    = 43,
    Obsolete44               = 44,
    Interface_Failed         = 45,
    Obsolete46               = 46,
    Too_Many_Redirects       = 47,
    Unknown_Option           = 48,
    Setopt_Option_Syntax     = 49,
    Obsolete50               = 50,
    Obsolete51               = 51,
    Got_Nothing              = 52,
    Ssl_Engine_Notfound      = 53,
    Ssl_Engine_Setfailed     = 54,
    Send_Error               = 55,
    Recv_Error               = 56,
    Obsolete57               = 57,
    Ssl_Certproblem          = 58,
    Ssl_Cipher               = 59,
    Peer_Failed_Verification = 60,
    Bad_Content_Encoding     = 61,
    Obsolete62               = 62,
    Filesize_Exceeded        = 63,
    Use_Ssl_Failed           = 64,
    Send_Fail_Rewind         = 65,
    Ssl_Engine_Initfailed    = 66,
    Login_Denied             = 67,
    Tftp_Notfound            = 68,
    Tftp_Perm                = 69,
    Remote_Disk_Full         = 70,
    Tftp_Illegal             = 71,
    Tftp_Unknownid           = 72,
    Remote_File_Exists       = 73,
    Tftp_Nosuchuser          = 74,
    Obsolete75               = 75,
    Obsolete76               = 76,
    Ssl_Cacert_Badfile       = 77,
    Remote_File_Not_Found    = 78,
    Ssh                      = 79,
    Ssl_Shutdown_Failed      = 80,
    Again                    = 81,
    Ssl_Crl_Badfile          = 82,
    Ssl_Issuer_Error         = 83,
    Ftp_Pret_Failed          = 84,
    Rtsp_Cseq_Error          = 85,
    Rtsp_Session_Error       = 86,
    Ftp_Bad_File_List        = 87,
    Chunk_Failed             = 88,
    No_Connection_Available  = 89,
    Ssl_Pinnedpubkeynotmatch = 90,
    Ssl_Invalidcertstatus    = 91,
    Http2_Stream             = 92,
    Recursive_Api_Call       = 93,
    Auth_Error               = 94,
    Http3                    = 95,
    Quic_Connect_Error       = 96,
    Proxy                    = 97,
    Ssl_Clientcert           = 98,
    Unrecoverable_Poll       = 99,
}

// Result codes from the multi interface (`CURLMcode`). `.Call_Multi_Perform` is
// not an error: it means `multi_perform` wants to be called again immediately.
Multi_Code :: enum c.int {
    Call_Multi_Perform    = -1,
    Ok                    = 0,
    Bad_Handle            = 1,
    Bad_Easy_Handle       = 2,
    Out_Of_Memory         = 3,
    Internal_Error        = 4,
    Bad_Socket            = 5,
    Unknown_Option        = 6,
    Added_Already         = 7,
    Recursive_Api_Call    = 8,
    Wakeup_Failure        = 9,
    Bad_Function_Argument = 10,
    Aborted_By_Callback   = 11,
    Unrecoverable_Poll    = 12,
}

// `CURLoption` values are a type tag plus an ordinal, exactly as curl.h composes
// them. curl also defines OFF_T (30000) and BLOB (40000); no option used here
// needs either, so passing the wrong C type is impossible by construction.

@(private)
OPTTYPE_LONG :: 0

@(private)
OPTTYPE_OBJECTPOINT :: 10000

@(private)
OPTTYPE_FUNCTIONPOINT :: 20000

// The subset of `CURLoption` this binding sets. Kept closed: adding an option
// means deciding which typed `setopt_*` wrapper carries it.
Option :: enum c.int {
    Low_Speed_Limit = OPTTYPE_LONG + 19,
    Low_Speed_Time  = OPTTYPE_LONG + 20,
    Post            = OPTTYPE_LONG + 47,
    Follow_Location = OPTTYPE_LONG + 52,
    Post_Field_Size = OPTTYPE_LONG + 60,
    Connect_Timeout = OPTTYPE_LONG + 78,
    Http_Get        = OPTTYPE_LONG + 80,
    No_Signal       = OPTTYPE_LONG + 99,
    Pipe_Wait       = OPTTYPE_LONG + 237,
    Write_Data      = OPTTYPE_OBJECTPOINT + 1,
    Url             = OPTTYPE_OBJECTPOINT + 2,
    Error_Buffer    = OPTTYPE_OBJECTPOINT + 10,
    Post_Fields     = OPTTYPE_OBJECTPOINT + 15,
    Http_Header     = OPTTYPE_OBJECTPOINT + 23,
    Header_Data     = OPTTYPE_OBJECTPOINT + 29,
    Write_Function  = OPTTYPE_FUNCTIONPOINT + 11,
    Header_Function = OPTTYPE_FUNCTIONPOINT + 79,
}

// `CURLINFO` values are a type tag plus an ordinal; only the long-typed status
// code is read here.

@(private)
INFOTYPE_LONG :: 0x200000

Info :: enum c.int {
    Response_Code = INFOTYPE_LONG + 2,
}

// Message kind from `multi_info_read` (`CURLMSG`).
Msg_Kind :: enum c.int {
    None = 0,
    Done = 1,
}

// One completed-transfer report (`struct CURLMsg`). Only `.Done` is ever sent, and
// only then does `data.result` hold the transfer's `CURLcode`.
Msg :: struct {
    kind: Msg_Kind,
    easy: ^Easy,
    data: struct #raw_union {
        whatever: rawptr,
        result:   Code,
    },
}

// The C layout: an int padded to pointer alignment, a pointer, a pointer-sized union.
#assert(offset_of(Msg, easy) == size_of(rawptr))
#assert(size_of(Msg) == 3 * size_of(rawptr))

// Shared signature of `CURLOPT_WRITEFUNCTION` and `CURLOPT_HEADERFUNCTION`
// (`curl_write_callback`). `buffer` is curl's own and is valid for the call only.
Write_Callback :: #type proc "c" (buffer: [^]byte, size: c.size_t, nitems: c.size_t, user: rawptr) -> c.size_t

// Returned from a write callback to fail the transfer with `.Write_Error`. Any
// return other than the full byte count has the same effect; this is the value
// curl documents for it.
WRITEFUNC_ERROR :: c.size_t(0xFFFFFFFF)

// Largest value a `long`-typed option can carry. 32-bit on Windows, 64-bit on
// the LP64 targets.
@(private)
LONG_MAX :: int(max(c.long))

// Minimum size of the buffer handed to `CURLOPT_ERRORBUFFER` (`CURL_ERROR_SIZE`).
ERROR_SIZE :: 256

// `CURL_GLOBAL_DEFAULT` = `CURL_GLOBAL_SSL | CURL_GLOBAL_WIN32`.
@(private)
GLOBAL_DEFAULT :: 1 | 2

// foreign import itself cannot be @(private); the c_* decls below are.
when ODIN_OS == .Windows {
    // Static libcurl built with Schannel by `libs/bindings/curl/build_static.bat`. A static
    // archive carries no import records, so its system dependencies — sockets,
    // the certificate store, and the crypto providers — are named here.
    foreign import lib {"bin/curl.lib", "system:ws2_32.lib", "system:crypt32.lib", "system:secur32.lib", "system:bcrypt.lib", "system:advapi32.lib"}
} else {
    foreign import lib "system:curl"
}

@(private, default_calling_convention = "c")
foreign lib {
    @(link_name = "curl_global_init")
    c_global_init :: proc(flags: c.long) -> Code ---

    @(link_name = "curl_easy_init")
    c_easy_init :: proc() -> ^Easy ---
    @(link_name = "curl_easy_cleanup")
    c_easy_cleanup :: proc(easy: ^Easy) ---
    @(link_name = "curl_easy_setopt")
    c_easy_setopt :: proc(easy: ^Easy, option: Option, #c_vararg args: ..any) -> Code ---
    @(link_name = "curl_easy_getinfo")
    c_easy_getinfo :: proc(easy: ^Easy, info: Info, #c_vararg args: ..any) -> Code ---
    @(link_name = "curl_easy_strerror")
    c_easy_strerror :: proc(code: Code) -> cstring ---

    @(link_name = "curl_slist_append")
    c_slist_append :: proc(list: ^Slist, value: cstring) -> ^Slist ---
    @(link_name = "curl_slist_free_all")
    c_slist_free_all :: proc(list: ^Slist) ---

    @(link_name = "curl_multi_init")
    c_multi_init :: proc() -> ^Multi ---
    @(link_name = "curl_multi_cleanup")
    c_multi_cleanup :: proc(multi: ^Multi) -> Multi_Code ---
    @(link_name = "curl_multi_add_handle")
    c_multi_add_handle :: proc(multi: ^Multi, easy: ^Easy) -> Multi_Code ---
    @(link_name = "curl_multi_remove_handle")
    c_multi_remove_handle :: proc(multi: ^Multi, easy: ^Easy) -> Multi_Code ---
    @(link_name = "curl_multi_perform")
    c_multi_perform :: proc(multi: ^Multi, running_handles: ^c.int) -> Multi_Code ---
    @(link_name = "curl_multi_timeout")
    c_multi_timeout :: proc(multi: ^Multi, milliseconds: ^c.long) -> Multi_Code ---
    @(link_name = "curl_multi_info_read")
    c_multi_info_read :: proc(multi: ^Multi, msgs_in_queue: ^c.int) -> ^Msg ---
    @(link_name = "curl_multi_strerror")
    c_multi_strerror :: proc(code: Multi_Code) -> cstring ---
}

// Typed setopt layer. `curl_easy_setopt` is variadic and therefore type-unsafe:
// an option taking a `long` handed an Odin `int` corrupts the call silently.
// These wrappers are the only callers of `c_easy_setopt` in the package.

// Sets a `long`-typed option.
@(private)
setopt_long :: proc(easy: ^Easy, option: Option, value: int) -> Code {
    assert(easy != nil, "setopt_long needs an easy handle")

    return c_easy_setopt(easy, option, c.long(value))
}

// Sets a string option. libcurl copies the string during this call, so `value`
// need not outlive it. `Post_Fields` is the one string-shaped option that does
// NOT copy — it goes through `setopt_ptr` instead.
@(private)
setopt_str :: proc(easy: ^Easy, option: Option, value: cstring) -> Code {
    assert(easy != nil, "setopt_str needs an easy handle")
    assert(value != nil, "setopt_str needs a value")

    return c_easy_setopt(easy, option, value)
}

// Sets a pointer option. The pointee is NOT copied and must outlive the transfer.
@(private)
setopt_ptr :: proc(easy: ^Easy, option: Option, value: rawptr) -> Code {
    assert(easy != nil, "setopt_ptr needs an easy handle")

    return c_easy_setopt(easy, option, value)
}

// Sets a `curl_write_callback`-shaped option, so the proc type is checked here
// rather than swallowed by the varargs.
@(private)
setopt_write_cb :: proc(easy: ^Easy, option: Option, value: Write_Callback) -> Code {
    assert(easy != nil, "setopt_write_cb needs an easy handle")
    assert(value != nil, "setopt_write_cb needs a callback")

    return c_easy_setopt(easy, option, rawptr(value))
}

// Reads a `long`-typed transfer info value.
@(private)
getinfo_long :: proc(easy: ^Easy, info: Info) -> (value: int, code: Code) {
    assert(easy != nil, "getinfo_long needs an easy handle")

    out: c.long
    code = c_easy_getinfo(easy, info, &out)

    return int(out), code
}

// Milliseconds curl wants to wait before the next `multi_perform`. A negative
// value means curl has no timer pending.
@(private)
multi_timeout_ms :: proc(multi: ^Multi) -> (ms: int, code: Multi_Code) {
    assert(multi != nil, "multi_timeout_ms needs a multi handle")

    out: c.long = -1
    code = c_multi_timeout(multi, &out)

    return int(out), code
}

// Next queued transfer report, or nil when the queue is drained. The message
// belongs to the multi handle and is invalidated by the next curl call on it.
@(private)
multi_info_read :: proc(multi: ^Multi) -> (msg: ^Msg, remaining: int) {
    assert(multi != nil, "multi_info_read needs a multi handle")

    out: c.int
    msg = c_multi_info_read(multi, &out)

    return msg, int(out)
}

// Number of easy handles the multi still holds after a `multi_perform`.
@(private)
multi_perform :: proc(multi: ^Multi) -> (running: int, code: Multi_Code) {
    assert(multi != nil, "multi_perform needs a multi handle")

    out: c.int
    code = c_multi_perform(multi, &out)

    return int(out), code
}
