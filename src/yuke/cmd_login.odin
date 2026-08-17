/*
yuke login (`yuke login`): device-code enrollment. Writes a daemon identity
(`credentials.json` / `identity.key`) and/or a client Session (`session.json` /
`session.key`) into `~/.local/share/yuke`. The two files are different principals.

The control-plane client (`src/relay`) is async on an nbio loop; login is a one-shot CLI, so
`cloud_post` drives that loop synchronously — start one transfer, tick until it settles.
*/
package main

import "core:crypto/ecdh"
import "core:fmt"
import "core:nbio"
import "core:os"
import "core:strings"
import "core:time"

import "src:paths"
import "src:relay"

import "libs:bindings/curl"

// Control-plane base URL when neither `--cloud` nor `YUKE_CLOUD_URL` is set. The device API is
// served only under the `platform` subdomain (yuke-cloud `config/routes.rb`), so the base must
// carry it. Defaults to the hosted control plane; a local dev server is selected with
// `--cloud http://platform.lvh.me:3000` (or `YUKE_CLOUD_URL`), where `platform.lvh.me` resolves
// to 127.0.0.1.
DEFAULT_CLOUD_URL :: "https://platform.yuke.sh"

// Environment override for the control-plane base URL.
CLOUD_URL_ENV :: "YUKE_CLOUD_URL"

// Config-directory mode: owner-only, matching the secrets it will hold.
LOGIN_DIR_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Execute_User}

// Per-request bounds for the enrollment calls.
LOGIN_CONNECT_TIMEOUT :: 10 * time.Second
LOGIN_REQUEST_TIMEOUT :: 30 * time.Second

// Parsed `yuke login` flags.
@(private = "file")
Login_Options :: struct {
    force:      bool,
    name:       string,
    cloud:      string,
    role:       string, // daemon | client | both
    kind:       string, // cli | token; client-only
    kind_set:   bool,
    device_ids: []string,
}

// The `login` subcommand: enroll this device and persist its identity.
login_run :: proc() {
    opts, args_ok := login_args_parse(os.args[2:])
    if !args_ok {
        os.exit(2)
    }

    if msg := paths.app_name_error(); msg != "" {
        fmt.eprintfln("yuke login: %s", msg)
        os.exit(1)
    }

    dir := paths.data_dir()
    if dir == "" {
        fmt.eprintln("yuke login: no data directory could be resolved")
        os.exit(1)
    }

    have_device := false
    have_session := false

    // Owned on the heap, not the temp arena: `existing_device_id` is borrowed into the session
    // save-view far below, past the poll loop, and a persisted field must not alias reusable
    // temp memory. Freed at proc exit for the normal return; os.exit paths leave it to the OS.
    existing_device_id := ""
    existing_session_id := ""
    defer if len(existing_device_id) > 0 {
        delete(existing_device_id, context.allocator)
    }
    defer if len(existing_session_id) > 0 {
        delete(existing_session_id, context.allocator)
    }
    if !opts.force {
        existing, ierr := relay.identity_load(dir)
        switch ierr {
        case .None:
            have_device = true
            existing_device_id, _ = strings.clone(existing.device_id, context.allocator)
            relay.identity_destroy(&existing)
        case .Absent:
        case .Stale:
            fmt.eprintfln(
                "yuke login: stale identity from before the device/session split; delete the files in %s or pass --force",
                dir,
            )
            os.exit(1)
        case .Unreadable, .Malformed, .Key_Invalid, .Write_Failed:
            fmt.eprintfln("yuke login: existing device identity is unreadable (%v); pass --force to overwrite", ierr)
            os.exit(1)
        }
        sess, serr := relay.session_identity_load(dir)
        switch serr {
        case .None:
            have_session = true
            existing_session_id, _ = strings.clone(sess.session_id, context.allocator)
            relay.session_identity_destroy(&sess)
        case .Absent, .Stale:
        case .Unreadable, .Malformed, .Key_Invalid, .Write_Failed:
            fmt.eprintfln("yuke login: existing session identity is unreadable (%v); pass --force to overwrite", serr)
            os.exit(1)
        }
    }

    if opts.role == "" {
        if !login_stdin_is_tty() {
            fmt.eprintln("yuke login: scripts must pass --role daemon, client, or both")
            os.exit(2)
        }
        if have_device && have_session {
            login_already_enrolled_both(existing_device_id, existing_session_id)
        }
        opts.role = login_prompt_role(have_device, have_session)
    }

    want_device := opts.role == "daemon" || opts.role == "both"
    want_session := opts.role == "client" || opts.role == "both"

    if !opts.force {
        if want_device && have_device && want_session && have_session {
            login_already_enrolled_both(existing_device_id, existing_session_id)
        }
        if want_device && have_device {
            fmt.printfln("already enrolled as daemon %s; pass --force to re-enroll", existing_device_id)
            if !want_session {
                os.exit(0)
            }
            want_device = false
        }
        if want_session && have_session {
            fmt.printfln("already enrolled as session %s; pass --force to re-enroll", existing_session_id)
            if !want_device {
                os.exit(0)
            }
            want_session = false
        }
    }

    intent := "daemon"
    if want_device && want_session {
        intent = "both"
    } else if want_session {
        intent = "client"
    } else if want_device {
        intent = "daemon"
    } else {
        os.exit(0)
    }

    if opts.role != "client" && (opts.kind_set || len(opts.device_ids) > 0) {
        fmt.eprintln("yuke login: --kind and --device-ids apply only to --role client; ignoring")
    }

    if mkerr := os.make_directory_all(dir, LOGIN_DIR_PERMISSIONS); mkerr != nil && !os.is_dir(dir) {
        fmt.eprintfln("yuke login: could not create %s: %v", dir, mkerr)
        os.exit(1)
    }

    static_key: ecdh.Private_Key
    if !ecdh.private_key_generate(&static_key, .X25519) {
        fmt.eprintln("yuke login: could not generate a device key")
        os.exit(1)
    }

    defer ecdh.private_key_clear(&static_key)

    pub: ecdh.Public_Key
    ecdh.public_key_set_priv(&pub, &static_key)
    pub_bytes: [relay.NOISE_STATIC_KEY_SIZE]u8
    ecdh.public_key_bytes(&pub, pub_bytes[:])

    if err := nbio.acquire_thread_event_loop(); err != nil {
        fmt.eprintfln("yuke login: event loop unavailable: %v", err)
        os.exit(1)
    }

    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    client: curl.Client
    if cerr := curl.client_init(&client, loop); cerr != .None {
        fmt.eprintfln("yuke login: HTTP client init failed: %v", cerr)
        os.exit(1)
    }

    defer curl.client_destroy(&client)

    // 1. Request a device code.
    pin: []u8
    if want_device {
        pin = pub_bytes[:]
    }
    session_kind := ""
    device_ids: []string
    if opts.role == "client" {
        session_kind = opts.kind if opts.kind != "" else "cli"
        device_ids = opts.device_ids
    }
    start_body, enc_err := relay.enroll_start_encode(
        opts.name,
        ODIN_OS_STRING,
        pin,
        intent,
        session_kind,
        device_ids,
        context.temp_allocator,
    )
    if enc_err != .None {
        fmt.eprintln("yuke login: could not build the enrollment request")
        os.exit(1)
    }

    start_url := strings.concatenate({opts.cloud, "/api/v1/device_codes"}, context.temp_allocator)
    status, body, req_ok := cloud_post(&client, start_url, start_body, context.temp_allocator)
    if !req_ok {
        fmt.eprintfln("yuke login: could not reach the control plane at %s", opts.cloud)
        os.exit(1)
    }

    if status != 200 && status != 201 {
        fmt.eprintfln("yuke login: enrollment request rejected (HTTP %d)", status)
        os.exit(1)
    }

    start, start_err := relay.enroll_start_decode(body, context.temp_allocator)
    if start_err != .None {
        fmt.eprintln("yuke login: the control plane returned an unexpected response")
        os.exit(1)
    }

    // 2. Ask the human to approve it.
    fmt.printfln("To authorize this device, open:\n\n  %s\n", start.verification_uri_complete)
    fmt.printfln("and confirm the code %s. Waiting for approval...", start.user_code)

    // 3. Poll until approved, denied, or expired.
    poll_body, poll_enc := relay.enroll_poll_encode(start.device_code, context.allocator)
    if poll_enc != .None {
        fmt.eprintln("yuke login: could not build the poll request")
        os.exit(1)
    }

    defer delete(poll_body, context.allocator)

    poll_url := strings.concatenate({opts.cloud, "/api/v1/device_codes/token"}, context.allocator)
    defer delete(poll_url, context.allocator)

    interval := time.Duration(max(start.interval, 1)) * time.Second
    deadline := time.time_add(time.now(), time.Duration(max(start.expires_in, 1)) * time.Second)

    for {
        time.sleep(interval)

        if time.since(deadline) >= 0 {
            fmt.eprintln("yuke login: enrollment expired before approval; run `yuke login` again")
            os.exit(1)
        }

        pstatus, pbody, pok := cloud_post(&client, poll_url, poll_body, context.allocator)
        if !pok {
            // A transient network error mid-poll is not fatal; keep waiting for approval.
            continue
        }

        outcome, cred, _ := relay.enroll_poll_decode(pstatus, pbody, context.allocator, intent)
        delete(pbody, context.allocator)

        switch outcome {
        case .Pending:
            continue

        case .Denied:
            fmt.eprintln("yuke login: the request was denied")
            os.exit(1)

        case .Expired:
            fmt.eprintln("yuke login: enrollment expired; run `yuke login` again")
            os.exit(1)

        case .Approved:
            if want_device {
                // Borrowed save-view: strings alias `cred`, so no allocator to free.
                id := relay.Identity {
                    device_id  = cred.device_id,
                    credential = cred.credential,
                    relay_url  = cred.relay_url,
                    static_key = static_key,
                }
                save_err := relay.identity_save(dir, &id, context.temp_allocator)
                if save_err != .None {
                    relay.identity_destroy(&id)
                    fmt.eprintfln("yuke login: could not write the device identity to %s: %v", dir, save_err)
                    os.exit(1)
                }
                fmt.printfln("Enrolled daemon %s (relay %s).", cred.device_id, cred.relay_url)
                relay.identity_destroy(&id)
            }
            if want_session {
                sess_cred := cred.session_credential if cred.session_credential != "" else cred.credential
                sess_id := cred.session_id
                session_key: ecdh.Private_Key
                sess_kind := "cli"
                if opts.role == "client" && session_kind != "" {
                    sess_kind = session_kind
                }
                has_key := sess_kind != "token"
                if has_key && !ecdh.private_key_generate(&session_key, .X25519) {
                    fmt.eprintln("yuke login: could not generate a session key")
                    os.exit(1)
                }
                // Borrowed save-view: strings alias `cred` and `kind` is a literal, so no
                // allocator — destroy must not `delete` them.
                sid := relay.Session_Identity {
                    session_id      = sess_id,
                    credential      = sess_cred,
                    relay_url       = cred.relay_url,
                    local_device_id = cred.device_id if cred.device_id != "" else existing_device_id,
                    kind            = sess_kind,
                    static_key      = session_key,
                    has_static_key  = has_key,
                }
                save_err := relay.session_identity_save(dir, &sid, context.temp_allocator)
                if save_err != .None {
                    relay.session_identity_destroy(&sid)
                    fmt.eprintfln("yuke login: could not write the session identity to %s: %v", dir, save_err)
                    os.exit(1)
                }
                fmt.printfln("Enrolled session %s.", sess_id)
                relay.session_identity_destroy(&sid)
            }

            return
        }
    }
}

// Parse `yuke login` flags. Unknown flag or missing value → ok=false.
@(private = "file")
login_args_parse :: proc(args: []string) -> (opts: Login_Options, ok: bool) {
    opts.cloud = login_default_cloud()
    opts.name = login_default_name()

    i := 0
    for i < len(args) {
        arg := args[i]

        if arg == "--force" {
            opts.force = true
            i += 1
            continue
        }

        v, matched, valid := login_flag_value(args, &i, "--role", "needs daemon, client, or both")
        if matched {
            opts.role = v
        } else if v, matched, valid = login_flag_value(args, &i, "--kind", "needs cli or token"); matched {
            opts.kind = v
            opts.kind_set = true
        } else if v, matched, valid = login_flag_value(args, &i, "--device-ids", "needs a comma-separated list");
           matched {
            opts.device_ids = login_parse_ids(v)
        } else if v, matched, valid = login_flag_value(args, &i, "--name", "needs a value"); matched {
            opts.name = v
        } else if v, matched, valid = login_flag_value(args, &i, "--cloud", "needs a value"); matched {
            opts.cloud = v
        } else {
            fmt.eprintfln("yuke login: unknown option %q", arg)
            return {}, false
        }

        if !valid {
            return {}, false
        }

        i += 1
    }

    if opts.name == "" {
        opts.name = "unknown device"
    }
    if opts.kind == "" {
        opts.kind = "cli"
    }
    if opts.role != "" && opts.role != "daemon" && opts.role != "client" && opts.role != "both" {
        fmt.eprintfln("yuke login: --role must be daemon, client, or both")
        return {}, false
    }
    if opts.kind != "cli" && opts.kind != "token" {
        fmt.eprintfln("yuke login: --kind must be cli or token")
        return {}, false
    }

    return opts, true
}

// Report that both principals are already present and exit cleanly. Nothing to enroll is not an
// error, so this is exit 0.
@(private = "file")
login_already_enrolled_both :: proc(device_id: string, session_id: string) -> ! {
    fmt.printfln("already enrolled as daemon %s and session %s; pass --force to re-enroll", device_id, session_id)
    os.exit(0)
}

@(private = "file")
login_prompt_role :: proc(have_device: bool, have_session: bool) -> string {
    default_choice := "1"
    if have_device && !have_session {
        default_choice = "3"
    } else if have_session && !have_device {
        default_choice = "2"
    }

    fmt.println("Enroll this machine as:")
    fmt.println()
    fmt.println("  [1] daemon + client   park yuked here and use yuke / the TUI")
    fmt.println("  [2] daemon only       headless host / CI runner that parks an agent")
    fmt.println("  [3] client only       no local daemon, or a token for CI")
    fmt.println()
    fmt.printf("Choice [%s]: ", default_choice)
    buf: [32]u8
    n, _ := os.read(os.stdin, buf[:])
    line := strings.trim_space(string(buf[:max(n, 0)]))
    if line == "" {
        line = default_choice
    }
    switch line {
    case "1":
        return "both"
    case "2":
        return "daemon"
    case "3":
        return "client"
    }
    fmt.eprintfln("yuke login: unknown choice %q", line)
    os.exit(1)
}

// Match one value-bearing flag at `args[i^]`, accepting both `--flag value` (consuming the
// following argument) and `--flag=value`. `matched` is false when this is a different argument;
// when it is this flag in the space form with no value, prints `yuke login: <name> <need>` and
// returns `ok=false`. The `--flag=` form permits an empty value.
@(private = "file")
login_flag_value :: proc(
    args: []string,
    i: ^int,
    name: string,
    need: string,
) -> (
    value: string,
    matched: bool,
    ok: bool,
) {
    arg := args[i^]

    if arg == name {
        if i^ + 1 >= len(args) {
            fmt.eprintfln("yuke login: %s %s", name, need)
            return "", true, false
        }

        i^ += 1
        return args[i^], true, true
    }

    if strings.has_prefix(arg, name) && len(arg) > len(name) && arg[len(name)] == '=' {
        return arg[len(name) + 1:], true, true
    }

    return "", false, true
}

@(private = "file")
login_parse_ids :: proc(raw: string) -> []string {
    parts := strings.split(raw, ",", context.temp_allocator)
    n := 0
    for part in parts {
        trimmed := strings.trim_space(part)
        if trimmed == "" {
            continue
        }
        parts[n] = trimmed
        n += 1
    }
    return parts[:n]
}

// The control-plane base URL: `$YUKE_CLOUD_URL` when set and non-empty, else the hosted default.
@(private = "file")
login_default_cloud :: proc() -> string {
    if v, set := os.lookup_env(CLOUD_URL_ENV, context.allocator); set && v != "" {
        return v
    }

    return DEFAULT_CLOUD_URL
}

// The default device name: OS hostname when available, else `"unknown device"`.
@(private = "file")
login_default_name :: proc() -> string {
    if name := login_hostname(); name != "" {
        return name
    }

    return "unknown device"
}

// One POST's accumulated response, filled by the curl callbacks below.
@(private = "file")
Cloud_Rx :: struct {
    status: int,
    body:   [dynamic]u8,
    code:   curl.Code,
    done:   bool,
}

// Perform one JSON POST and block until it settles, ticking the loop the curl client runs on.
// `resp` is allocated from `allocator` and owned by the caller. `ok` is false only on a transport
// failure (no HTTP response arrived); an HTTP error status returns ok with that status and body.
@(private = "file")
cloud_post :: proc(
    client: ^curl.Client,
    url: string,
    body: []u8,
    allocator := context.allocator,
) -> (
    status: int,
    resp: []u8,
    ok: bool,
) {
    rx: Cloud_Rx
    rx.body.allocator = allocator

    headers := []curl.Header{{name = "Content-Type", value = "application/json"}}
    req := curl.Request {
        url             = strings.clone_to_cstring(url, context.temp_allocator),
        method          = .Post,
        body            = body,
        headers         = headers,
        connect_timeout = LOGIN_CONNECT_TIMEOUT,
        total_timeout   = LOGIN_REQUEST_TIMEOUT,
    }

    transfer: curl.Transfer
    cbs := curl.Callbacks {
        on_status = cloud_on_status,
        on_body   = cloud_on_body,
        on_done   = cloud_on_done,
    }
    if serr := curl.transfer_start(&transfer, client, req, cbs, &rx); serr != .None {
        delete(rx.body)

        return 0, nil, false
    }

    for !rx.done {
        if terr := nbio.tick(50 * time.Millisecond); terr != nil {
            // The transfer may have completed in the same tick that reported the loop error;
            // `transfer_cancel` requires a still-running transfer, so only cancel a live one.
            if !rx.done {
                curl.transfer_cancel(&transfer)
            }

            delete(rx.body)

            return 0, nil, false
        }
    }

    if rx.code != .Ok {
        delete(rx.body)

        return rx.status, nil, false
    }

    return rx.status, rx.body[:], true
}

@(private = "file")
cloud_on_status :: proc(user: rawptr, status: int) {
    (^Cloud_Rx)(user).status = status
}

@(private = "file")
cloud_on_body :: proc(user: rawptr, chunk: []byte) -> bool {
    rx := (^Cloud_Rx)(user)
    if _, aerr := append(&rx.body, ..chunk); aerr != nil {
        return false
    }

    return true
}

@(private = "file")
cloud_on_done :: proc(user: rawptr, result: curl.Result) {
    rx := (^Cloud_Rx)(user)
    rx.code = result.code
    if result.status != 0 {
        rx.status = result.status
    }

    rx.done = true
}
