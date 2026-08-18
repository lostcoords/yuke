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
// them. The `STRINGPOINT`, `SLISTPOINT`, `CBPOINT`, and `VALUES` aliases are
// curl.h's own and record which C type an option takes.

@(private)
OPTTYPE_LONG :: 0

@(private)
OPTTYPE_VALUES :: OPTTYPE_LONG

@(private)
OPTTYPE_OBJECTPOINT :: 10000

@(private)
OPTTYPE_STRINGPOINT :: OPTTYPE_OBJECTPOINT

@(private)
OPTTYPE_SLISTPOINT :: OPTTYPE_OBJECTPOINT

@(private)
OPTTYPE_CBPOINT :: OPTTYPE_OBJECTPOINT

@(private)
OPTTYPE_FUNCTIONPOINT :: 20000

@(private)
OPTTYPE_OFF_T :: 30000

@(private)
OPTTYPE_BLOB :: 40000

// Every `CURLoption` curl.h defines, in its order. `OFF_T` and `BLOB` options
// are names only: no typed `setopt_*` wrapper carries them yet.
Option :: enum c.int {
    // `CURLOPT_WRITEDATA` https://curl.se/libcurl/c/CURLOPT_WRITEDATA.html
    Write_Data                 = OPTTYPE_CBPOINT + 1,
    // `CURLOPT_URL` https://curl.se/libcurl/c/CURLOPT_URL.html
    Url                        = OPTTYPE_STRINGPOINT + 2,
    Port                       = OPTTYPE_LONG + 3,
    Proxy                      = OPTTYPE_STRINGPOINT + 4,
    User_Pwd                   = OPTTYPE_STRINGPOINT + 5,
    Proxy_User_Pwd             = OPTTYPE_STRINGPOINT + 6,
    Range                      = OPTTYPE_STRINGPOINT + 7,
    Read_Data                  = OPTTYPE_CBPOINT + 9,
    // `CURLOPT_ERRORBUFFER` https://curl.se/libcurl/c/CURLOPT_ERRORBUFFER.html
    Error_Buffer               = OPTTYPE_OBJECTPOINT + 10,
    // `CURLOPT_WRITEFUNCTION` https://curl.se/libcurl/c/CURLOPT_WRITEFUNCTION.html
    Write_Function             = OPTTYPE_FUNCTIONPOINT + 11,
    Read_Function              = OPTTYPE_FUNCTIONPOINT + 12,
    // `CURLOPT_TIMEOUT` https://curl.se/libcurl/c/CURLOPT_TIMEOUT.html
    Timeout                    = OPTTYPE_LONG + 13,
    In_File_Size               = OPTTYPE_LONG + 14,
    Post_Fields                = OPTTYPE_OBJECTPOINT + 15,
    Referer                    = OPTTYPE_STRINGPOINT + 16,
    Ftp_Port                   = OPTTYPE_STRINGPOINT + 17,
    User_Agent                 = OPTTYPE_STRINGPOINT + 18,
    Low_Speed_Limit            = OPTTYPE_LONG + 19,
    // `CURLOPT_LOW_SPEED_TIME` https://curl.se/libcurl/c/CURLOPT_LOW_SPEED_TIME.html
    Low_Speed_Time             = OPTTYPE_LONG + 20,
    Resume_From                = OPTTYPE_LONG + 21,
    Cookie                     = OPTTYPE_STRINGPOINT + 22,
    // `CURLOPT_HTTPHEADER` https://curl.se/libcurl/c/CURLOPT_HTTPHEADER.html
    Http_Header                = OPTTYPE_SLISTPOINT + 23,
    Http_Post                  = OPTTYPE_OBJECTPOINT + 24,
    Ssl_Cert                   = OPTTYPE_STRINGPOINT + 25,
    Key_Passwd                 = OPTTYPE_STRINGPOINT + 26,
    Crlf                       = OPTTYPE_LONG + 27,
    Quote                      = OPTTYPE_SLISTPOINT + 28,
    // `CURLOPT_HEADERDATA` https://curl.se/libcurl/c/CURLOPT_HEADERDATA.html
    Header_Data                = OPTTYPE_CBPOINT + 29,
    Cookie_File                = OPTTYPE_STRINGPOINT + 31,
    Ssl_Version                = OPTTYPE_VALUES + 32,
    Time_Condition             = OPTTYPE_VALUES + 33,
    Time_Value                 = OPTTYPE_LONG + 34,
    Custom_Request             = OPTTYPE_STRINGPOINT + 36,
    Stderr                     = OPTTYPE_OBJECTPOINT + 37,
    Post_Quote                 = OPTTYPE_SLISTPOINT + 39,
    Obsolete40                 = OPTTYPE_OBJECTPOINT + 40,
    Verbose                    = OPTTYPE_LONG + 41,
    Header                     = OPTTYPE_LONG + 42,
    No_Progress                = OPTTYPE_LONG + 43,
    No_Body                    = OPTTYPE_LONG + 44,
    Fail_On_Error              = OPTTYPE_LONG + 45,
    Upload                     = OPTTYPE_LONG + 46,
    // `CURLOPT_POST` https://curl.se/libcurl/c/CURLOPT_POST.html
    Post                       = OPTTYPE_LONG + 47,
    Dir_List_Only              = OPTTYPE_LONG + 48,
    Append                     = OPTTYPE_LONG + 50,
    Netrc                      = OPTTYPE_VALUES + 51,
    // `CURLOPT_FOLLOWLOCATION` https://curl.se/libcurl/c/CURLOPT_FOLLOWLOCATION.html
    Follow_Location            = OPTTYPE_LONG + 52,
    Transfer_Text              = OPTTYPE_LONG + 53,
    Put                        = OPTTYPE_LONG + 54,
    Progress_Function          = OPTTYPE_FUNCTIONPOINT + 56,
    Xfer_Info_Data             = OPTTYPE_CBPOINT + 57,
    Auto_Referer               = OPTTYPE_LONG + 58,
    Proxy_Port                 = OPTTYPE_LONG + 59,
    // `CURLOPT_POSTFIELDSIZE` https://curl.se/libcurl/c/CURLOPT_POSTFIELDSIZE.html
    Post_Field_Size            = OPTTYPE_LONG + 60,
    Http_Proxy_Tunnel          = OPTTYPE_LONG + 61,
    Interface                  = OPTTYPE_STRINGPOINT + 62,
    Krb_Level                  = OPTTYPE_STRINGPOINT + 63,
    Ssl_Verify_Peer            = OPTTYPE_LONG + 64,
    // `CURLOPT_CAINFO` https://curl.se/libcurl/c/CURLOPT_CAINFO.html
    Ca_Info                    = OPTTYPE_STRINGPOINT + 65,
    Max_Redirs                 = OPTTYPE_LONG + 68,
    File_Time                  = OPTTYPE_LONG + 69,
    Telnet_Options             = OPTTYPE_SLISTPOINT + 70,
    Max_Connects               = OPTTYPE_LONG + 71,
    Obsolete72                 = OPTTYPE_LONG + 72,
    Fresh_Connect              = OPTTYPE_LONG + 74,
    Forbid_Reuse               = OPTTYPE_LONG + 75,
    Random_File                = OPTTYPE_STRINGPOINT + 76,
    Egd_Socket                 = OPTTYPE_STRINGPOINT + 77,
    // `CURLOPT_CONNECTTIMEOUT` https://curl.se/libcurl/c/CURLOPT_CONNECTTIMEOUT.html
    Connect_Timeout            = OPTTYPE_LONG + 78,
    // `CURLOPT_HEADERFUNCTION` https://curl.se/libcurl/c/CURLOPT_HEADERFUNCTION.html
    Header_Function            = OPTTYPE_FUNCTIONPOINT + 79,
    // `CURLOPT_HTTPGET` https://curl.se/libcurl/c/CURLOPT_HTTPGET.html
    Http_Get                   = OPTTYPE_LONG + 80,
    Ssl_Verify_Host            = OPTTYPE_LONG + 81,
    Cookie_Jar                 = OPTTYPE_STRINGPOINT + 82,
    Ssl_Cipher_List            = OPTTYPE_STRINGPOINT + 83,
    // `CURLOPT_HTTP_VERSION` https://curl.se/libcurl/c/CURLOPT_HTTP_VERSION.html
    Http_Version               = OPTTYPE_VALUES + 84,
    Ftp_Use_Epsv               = OPTTYPE_LONG + 85,
    Ssl_Cert_Type              = OPTTYPE_STRINGPOINT + 86,
    Ssl_Key                    = OPTTYPE_STRINGPOINT + 87,
    Ssl_Key_Type               = OPTTYPE_STRINGPOINT + 88,
    Ssl_Engine                 = OPTTYPE_STRINGPOINT + 89,
    Ssl_Engine_Default         = OPTTYPE_LONG + 90,
    Dns_Use_Global_Cache       = OPTTYPE_LONG + 91,
    Dns_Cache_Timeout          = OPTTYPE_LONG + 92,
    Pre_Quote                  = OPTTYPE_SLISTPOINT + 93,
    Debug_Function             = OPTTYPE_FUNCTIONPOINT + 94,
    Debug_Data                 = OPTTYPE_CBPOINT + 95,
    Cookie_Session             = OPTTYPE_LONG + 96,
    Ca_Path                    = OPTTYPE_STRINGPOINT + 97,
    Buffer_Size                = OPTTYPE_LONG + 98,
    // `CURLOPT_NOSIGNAL` https://curl.se/libcurl/c/CURLOPT_NOSIGNAL.html
    No_Signal                  = OPTTYPE_LONG + 99,
    Share                      = OPTTYPE_OBJECTPOINT + 100,
    Proxy_Type                 = OPTTYPE_VALUES + 101,
    Accept_Encoding            = OPTTYPE_STRINGPOINT + 102,
    Private                    = OPTTYPE_OBJECTPOINT + 103,
    Http_200_Aliases           = OPTTYPE_SLISTPOINT + 104,
    Unrestricted_Auth          = OPTTYPE_LONG + 105,
    Ftp_Use_Eprt               = OPTTYPE_LONG + 106,
    Http_Auth                  = OPTTYPE_VALUES + 107,
    Ssl_Ctx_Function           = OPTTYPE_FUNCTIONPOINT + 108,
    Ssl_Ctx_Data               = OPTTYPE_CBPOINT + 109,
    Ftp_Create_Missing_Dirs    = OPTTYPE_LONG + 110,
    Proxy_Auth                 = OPTTYPE_VALUES + 111,
    Server_Response_Timeout    = OPTTYPE_LONG + 112,
    Ip_Resolve                 = OPTTYPE_VALUES + 113,
    Max_File_Size              = OPTTYPE_LONG + 114,
    In_File_Size_Large         = OPTTYPE_OFF_T + 115,
    Resume_From_Large          = OPTTYPE_OFF_T + 116,
    Max_File_Size_Large        = OPTTYPE_OFF_T + 117,
    Netrc_File                 = OPTTYPE_STRINGPOINT + 118,
    Use_Ssl                    = OPTTYPE_VALUES + 119,
    Post_Field_Size_Large      = OPTTYPE_OFF_T + 120,
    Tcp_No_Delay               = OPTTYPE_LONG + 121,
    Ftp_Ssl_Auth               = OPTTYPE_VALUES + 129,
    Ioctl_Function             = OPTTYPE_FUNCTIONPOINT + 130,
    Ioctl_Data                 = OPTTYPE_CBPOINT + 131,
    Ftp_Account                = OPTTYPE_STRINGPOINT + 134,
    Cookie_List                = OPTTYPE_STRINGPOINT + 135,
    Ignore_Content_Length      = OPTTYPE_LONG + 136,
    Ftp_Skip_Pasv_Ip           = OPTTYPE_LONG + 137,
    Ftp_File_Method            = OPTTYPE_VALUES + 138,
    Local_Port                 = OPTTYPE_LONG + 139,
    Local_Port_Range           = OPTTYPE_LONG + 140,
    // `CURLOPT_CONNECT_ONLY` https://curl.se/libcurl/c/CURLOPT_CONNECT_ONLY.html
    Connect_Only               = OPTTYPE_LONG + 141,
    Conv_From_Network_Function = OPTTYPE_FUNCTIONPOINT + 142,
    Conv_To_Network_Function   = OPTTYPE_FUNCTIONPOINT + 143,
    Conv_From_Utf8_Function    = OPTTYPE_FUNCTIONPOINT + 144,
    Max_Send_Speed_Large       = OPTTYPE_OFF_T + 145,
    Max_Recv_Speed_Large       = OPTTYPE_OFF_T + 146,
    Ftp_Alternative_To_User    = OPTTYPE_STRINGPOINT + 147,
    Sock_Opt_Function          = OPTTYPE_FUNCTIONPOINT + 148,
    Sock_Opt_Data              = OPTTYPE_CBPOINT + 149,
    Ssl_Session_Id_Cache       = OPTTYPE_LONG + 150,
    Ssh_Auth_Types             = OPTTYPE_VALUES + 151,
    Ssh_Public_Key_File        = OPTTYPE_STRINGPOINT + 152,
    Ssh_Private_Key_File       = OPTTYPE_STRINGPOINT + 153,
    Ftp_Ssl_Ccc                = OPTTYPE_LONG + 154,
    Timeout_Ms                 = OPTTYPE_LONG + 155,
    Connect_Timeout_Ms         = OPTTYPE_LONG + 156,
    Http_Transfer_Decoding     = OPTTYPE_LONG + 157,
    Http_Content_Decoding      = OPTTYPE_LONG + 158,
    New_File_Perms             = OPTTYPE_LONG + 159,
    New_Directory_Perms        = OPTTYPE_LONG + 160,
    Post_Redir                 = OPTTYPE_VALUES + 161,
    Ssh_Host_Public_Key_Md5    = OPTTYPE_STRINGPOINT + 162,
    Open_Socket_Function       = OPTTYPE_FUNCTIONPOINT + 163,
    Open_Socket_Data           = OPTTYPE_CBPOINT + 164,
    // `CURLOPT_COPYPOSTFIELDS` https://curl.se/libcurl/c/CURLOPT_COPYPOSTFIELDS.html
    Copy_Post_Fields           = OPTTYPE_OBJECTPOINT + 165,
    Proxy_Transfer_Mode        = OPTTYPE_LONG + 166,
    Seek_Function              = OPTTYPE_FUNCTIONPOINT + 167,
    Seek_Data                  = OPTTYPE_CBPOINT + 168,
    Crl_File                   = OPTTYPE_STRINGPOINT + 169,
    Issuer_Cert                = OPTTYPE_STRINGPOINT + 170,
    Address_Scope              = OPTTYPE_LONG + 171,
    Cert_Info                  = OPTTYPE_LONG + 172,
    Username                   = OPTTYPE_STRINGPOINT + 173,
    Password                   = OPTTYPE_STRINGPOINT + 174,
    Proxy_Username             = OPTTYPE_STRINGPOINT + 175,
    Proxy_Password             = OPTTYPE_STRINGPOINT + 176,
    No_Proxy                   = OPTTYPE_STRINGPOINT + 177,
    Tftp_Blk_Size              = OPTTYPE_LONG + 178,
    Socks5_Gssapi_Service      = OPTTYPE_STRINGPOINT + 179,
    Socks5_Gssapi_Nec          = OPTTYPE_LONG + 180,
    Protocols                  = OPTTYPE_LONG + 181,
    Redir_Protocols            = OPTTYPE_LONG + 182,
    Ssh_Known_Hosts            = OPTTYPE_STRINGPOINT + 183,
    Ssh_Key_Function           = OPTTYPE_FUNCTIONPOINT + 184,
    Ssh_Key_Data               = OPTTYPE_CBPOINT + 185,
    Mail_From                  = OPTTYPE_STRINGPOINT + 186,
    Mail_Rcpt                  = OPTTYPE_SLISTPOINT + 187,
    Ftp_Use_Pret               = OPTTYPE_LONG + 188,
    Rtsp_Request               = OPTTYPE_VALUES + 189,
    Rtsp_Session_Id            = OPTTYPE_STRINGPOINT + 190,
    Rtsp_Stream_Uri            = OPTTYPE_STRINGPOINT + 191,
    Rtsp_Transport             = OPTTYPE_STRINGPOINT + 192,
    Rtsp_Client_Cseq           = OPTTYPE_LONG + 193,
    Rtsp_Server_Cseq           = OPTTYPE_LONG + 194,
    Interleave_Data            = OPTTYPE_CBPOINT + 195,
    Interleave_Function        = OPTTYPE_FUNCTIONPOINT + 196,
    Wildcard_Match             = OPTTYPE_LONG + 197,
    Chunk_Bgn_Function         = OPTTYPE_FUNCTIONPOINT + 198,
    Chunk_End_Function         = OPTTYPE_FUNCTIONPOINT + 199,
    Fnmatch_Function           = OPTTYPE_FUNCTIONPOINT + 200,
    Chunk_Data                 = OPTTYPE_CBPOINT + 201,
    Fnmatch_Data               = OPTTYPE_CBPOINT + 202,
    Resolve                    = OPTTYPE_SLISTPOINT + 203,
    Tls_Auth_Username          = OPTTYPE_STRINGPOINT + 204,
    Tls_Auth_Password          = OPTTYPE_STRINGPOINT + 205,
    Tls_Auth_Type              = OPTTYPE_STRINGPOINT + 206,
    Transfer_Encoding          = OPTTYPE_LONG + 207,
    Close_Socket_Function      = OPTTYPE_FUNCTIONPOINT + 208,
    Close_Socket_Data          = OPTTYPE_CBPOINT + 209,
    Gssapi_Delegation          = OPTTYPE_VALUES + 210,
    Dns_Servers                = OPTTYPE_STRINGPOINT + 211,
    Accept_Timeout_Ms          = OPTTYPE_LONG + 212,
    Tcp_Keep_Alive             = OPTTYPE_LONG + 213,
    Tcp_Keep_Idle              = OPTTYPE_LONG + 214,
    Tcp_Keep_Intvl             = OPTTYPE_LONG + 215,
    Ssl_Options                = OPTTYPE_VALUES + 216,
    Mail_Auth                  = OPTTYPE_STRINGPOINT + 217,
    Sasl_Ir                    = OPTTYPE_LONG + 218,
    Xfer_Info_Function         = OPTTYPE_FUNCTIONPOINT + 219,
    Xoauth2_Bearer             = OPTTYPE_STRINGPOINT + 220,
    Dns_Interface              = OPTTYPE_STRINGPOINT + 221,
    Dns_Local_Ip4              = OPTTYPE_STRINGPOINT + 222,
    Dns_Local_Ip6              = OPTTYPE_STRINGPOINT + 223,
    Login_Options              = OPTTYPE_STRINGPOINT + 224,
    Ssl_Enable_Npn             = OPTTYPE_LONG + 225,
    Ssl_Enable_Alpn            = OPTTYPE_LONG + 226,
    Expect_100_Timeout_Ms      = OPTTYPE_LONG + 227,
    Proxy_Header               = OPTTYPE_SLISTPOINT + 228,
    Header_Opt                 = OPTTYPE_VALUES + 229,
    Pinned_Public_Key          = OPTTYPE_STRINGPOINT + 230,
    Unix_Socket_Path           = OPTTYPE_STRINGPOINT + 231,
    Ssl_Verify_Status          = OPTTYPE_LONG + 232,
    Ssl_False_Start            = OPTTYPE_LONG + 233,
    Path_As_Is                 = OPTTYPE_LONG + 234,
    Proxy_Service_Name         = OPTTYPE_STRINGPOINT + 235,
    Service_Name               = OPTTYPE_STRINGPOINT + 236,
    // `CURLOPT_PIPEWAIT` https://curl.se/libcurl/c/CURLOPT_PIPEWAIT.html
    Pipe_Wait                  = OPTTYPE_LONG + 237,
    Default_Protocol           = OPTTYPE_STRINGPOINT + 238,
    Stream_Weight              = OPTTYPE_LONG + 239,
    Stream_Depends             = OPTTYPE_OBJECTPOINT + 240,
    Stream_Depends_E           = OPTTYPE_OBJECTPOINT + 241,
    Tftp_No_Options            = OPTTYPE_LONG + 242,
    Connect_To                 = OPTTYPE_SLISTPOINT + 243,
    Tcp_Fast_Open              = OPTTYPE_LONG + 244,
    Keep_Sending_On_Error      = OPTTYPE_LONG + 245,
    Proxy_Ca_Info              = OPTTYPE_STRINGPOINT + 246,
    Proxy_Ca_Path              = OPTTYPE_STRINGPOINT + 247,
    Proxy_Ssl_Verify_Peer      = OPTTYPE_LONG + 248,
    Proxy_Ssl_Verify_Host      = OPTTYPE_LONG + 249,
    Proxy_Ssl_Version          = OPTTYPE_VALUES + 250,
    Proxy_Tls_Auth_Username    = OPTTYPE_STRINGPOINT + 251,
    Proxy_Tls_Auth_Password    = OPTTYPE_STRINGPOINT + 252,
    Proxy_Tls_Auth_Type        = OPTTYPE_STRINGPOINT + 253,
    Proxy_Ssl_Cert             = OPTTYPE_STRINGPOINT + 254,
    Proxy_Ssl_Cert_Type        = OPTTYPE_STRINGPOINT + 255,
    Proxy_Ssl_Key              = OPTTYPE_STRINGPOINT + 256,
    Proxy_Ssl_Key_Type         = OPTTYPE_STRINGPOINT + 257,
    Proxy_Key_Passwd           = OPTTYPE_STRINGPOINT + 258,
    Proxy_Ssl_Cipher_List      = OPTTYPE_STRINGPOINT + 259,
    Proxy_Crl_File             = OPTTYPE_STRINGPOINT + 260,
    Proxy_Ssl_Options          = OPTTYPE_LONG + 261,
    Pre_Proxy                  = OPTTYPE_STRINGPOINT + 262,
    Proxy_Pinned_Public_Key    = OPTTYPE_STRINGPOINT + 263,
    Abstract_Unix_Socket       = OPTTYPE_STRINGPOINT + 264,
    Suppress_Connect_Headers   = OPTTYPE_LONG + 265,
    Request_Target             = OPTTYPE_STRINGPOINT + 266,
    Socks5_Auth                = OPTTYPE_LONG + 267,
    Ssh_Compression            = OPTTYPE_LONG + 268,
    Mime_Post                  = OPTTYPE_OBJECTPOINT + 269,
    Time_Value_Large           = OPTTYPE_OFF_T + 270,
    Happy_Eyeballs_Timeout_Ms  = OPTTYPE_LONG + 271,
    Resolver_Start_Function    = OPTTYPE_FUNCTIONPOINT + 272,
    Resolver_Start_Data        = OPTTYPE_CBPOINT + 273,
    Haproxy_Protocol           = OPTTYPE_LONG + 274,
    Dns_Shuffle_Addresses      = OPTTYPE_LONG + 275,
    Tls13_Ciphers              = OPTTYPE_STRINGPOINT + 276,
    Proxy_Tls13_Ciphers        = OPTTYPE_STRINGPOINT + 277,
    Disallow_Username_In_Url   = OPTTYPE_LONG + 278,
    Doh_Url                    = OPTTYPE_STRINGPOINT + 279,
    Upload_Buffer_Size         = OPTTYPE_LONG + 280,
    Upkeep_Interval_Ms         = OPTTYPE_LONG + 281,
    Curlu                      = OPTTYPE_OBJECTPOINT + 282,
    Trailer_Function           = OPTTYPE_FUNCTIONPOINT + 283,
    Trailer_Data               = OPTTYPE_CBPOINT + 284,
    Http09_Allowed             = OPTTYPE_LONG + 285,
    Alt_Svc_Ctrl               = OPTTYPE_LONG + 286,
    Alt_Svc                    = OPTTYPE_STRINGPOINT + 287,
    Max_Age_Conn               = OPTTYPE_LONG + 288,
    Sasl_Authzid               = OPTTYPE_STRINGPOINT + 289,
    Mail_Rcpt_Allow_Fails      = OPTTYPE_LONG + 290,
    Ssl_Cert_Blob              = OPTTYPE_BLOB + 291,
    Ssl_Key_Blob               = OPTTYPE_BLOB + 292,
    Proxy_Ssl_Cert_Blob        = OPTTYPE_BLOB + 293,
    Proxy_Ssl_Key_Blob         = OPTTYPE_BLOB + 294,
    Issuer_Cert_Blob           = OPTTYPE_BLOB + 295,
    Proxy_Issuer_Cert          = OPTTYPE_STRINGPOINT + 296,
    Proxy_Issuer_Cert_Blob     = OPTTYPE_BLOB + 297,
    Ssl_Ec_Curves              = OPTTYPE_STRINGPOINT + 298,
    Hsts_Ctrl                  = OPTTYPE_LONG + 299,
    Hsts                       = OPTTYPE_STRINGPOINT + 300,
    Hsts_Read_Function         = OPTTYPE_FUNCTIONPOINT + 301,
    Hsts_Read_Data             = OPTTYPE_CBPOINT + 302,
    Hsts_Write_Function        = OPTTYPE_FUNCTIONPOINT + 303,
    Hsts_Write_Data            = OPTTYPE_CBPOINT + 304,
    Aws_Sigv4                  = OPTTYPE_STRINGPOINT + 305,
    Doh_Ssl_Verify_Peer        = OPTTYPE_LONG + 306,
    Doh_Ssl_Verify_Host        = OPTTYPE_LONG + 307,
    Doh_Ssl_Verify_Status      = OPTTYPE_LONG + 308,
    Ca_Info_Blob               = OPTTYPE_BLOB + 309,
    Proxy_Ca_Info_Blob         = OPTTYPE_BLOB + 310,
    Ssh_Host_Public_Key_Sha256 = OPTTYPE_STRINGPOINT + 311,
    Pre_Req_Function           = OPTTYPE_FUNCTIONPOINT + 312,
    Pre_Req_Data               = OPTTYPE_CBPOINT + 313,
    Max_Lifetime_Conn          = OPTTYPE_LONG + 314,
    Mime_Options               = OPTTYPE_LONG + 315,
    Ssh_Host_Key_Function      = OPTTYPE_FUNCTIONPOINT + 316,
    Ssh_Host_Key_Data          = OPTTYPE_CBPOINT + 317,
    // `CURLOPT_PROTOCOLS_STR` https://curl.se/libcurl/c/CURLOPT_PROTOCOLS_STR.html
    Protocols_Str              = OPTTYPE_STRINGPOINT + 318,
    Redir_Protocols_Str        = OPTTYPE_STRINGPOINT + 319,
    Ws_Options                 = OPTTYPE_LONG + 320,
    Ca_Cache_Timeout           = OPTTYPE_LONG + 321,
    Quick_Exit                 = OPTTYPE_LONG + 322,
    Haproxy_Client_Ip          = OPTTYPE_STRINGPOINT + 323,
    Server_Response_Timeout_Ms = OPTTYPE_LONG + 324,
}

// `CURLINFO` values are a type tag plus an ordinal.

@(private)
INFOTYPE_LONG :: 0x200000

@(private)
INFOTYPE_SOCKET :: 0x500000

Info :: enum c.int {
    Response_Code = INFOTYPE_LONG + 2,
    Active_Socket = INFOTYPE_SOCKET + 44,
}

// `curl_socket_t`: a `SOCKET` handle on Windows, a file descriptor elsewhere.
// `net.Socket` is a `distinct i64`, wide enough for either, so a handle read back
// from curl casts straight to one.
when ODIN_OS == .Windows {
    Socket_Handle :: distinct uintptr
} else {
    Socket_Handle :: distinct c.int
}

// `CURL_SOCKET_BAD`: what `Active_Socket` reports once a handle has no connection.
SOCKET_BAD :: Socket_Handle(~uintptr(0)) when ODIN_OS == .Windows else Socket_Handle(-1)

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

// Shared signature of `Option.Write_Function` and `Option.Header_Function`
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

// `CURL_HTTP_VERSION_1_1`, the only `Http_Version` value this package sets.
HTTP_VERSION_1_1 :: 2

// Minimum size of the buffer handed to `Option.Error_Buffer` (`CURL_ERROR_SIZE`).
ERROR_SIZE :: 256

// `CURL_GLOBAL_DEFAULT` = `CURL_GLOBAL_SSL | CURL_GLOBAL_WIN32`.
@(private)
GLOBAL_DEFAULT :: 1 | 2

// foreign import itself cannot be @(private); the c_* decls below are.
when ODIN_OS == .Windows {
    // Static libcurl built with Schannel by `libs/bindings/curl/build_static.bat`. A static
    // archive carries no import records, so its system dependencies — sockets,
    // the certificate store, and the crypto providers — are named here.
    foreign import lib {"bin/curl.lib", "system:ws2_32.lib", "system:crypt32.lib", "system:secur32.lib", "system:bcrypt.lib", "system:advapi32.lib", "system:iphlpapi.lib"} // `if_nametoindex`, which curl resolves scope ids with.
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

    // Raw transfer on a `Connect_Only` connection. Both report `.Again` when the
    // socket is not ready; neither is usable before the connect completes.
    @(link_name = "curl_easy_send")
    c_easy_send :: proc(easy: ^Easy, buffer: rawptr, buflen: c.size_t, sent: ^c.size_t) -> Code ---
    @(link_name = "curl_easy_recv")
    c_easy_recv :: proc(easy: ^Easy, buffer: rawptr, buflen: c.size_t, received: ^c.size_t) -> Code ---

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
// need not outlive it.
@(private)
setopt_str :: proc(easy: ^Easy, option: Option, value: cstring) -> Code {
    assert(easy != nil, "setopt_str needs an easy handle")
    assert(value != nil, "setopt_str needs a value")

    return c_easy_setopt(easy, option, value)
}

// Sets a pointer option. Retention is per-option: callback data and the error
// buffer are retained, `Http_Header` retains the list, `Copy_Post_Fields` copies.
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

// Reads a socket-typed transfer info value.
@(private)
getinfo_socket :: proc(easy: ^Easy, info: Info) -> (value: Socket_Handle, code: Code) {
    assert(easy != nil, "getinfo_socket needs an easy handle")

    out: Socket_Handle
    code = c_easy_getinfo(easy, info, &out)

    return out, code
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
