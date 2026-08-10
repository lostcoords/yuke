/*
yuke login (`yuke login`): device-code enrollment. Generates the device's X25519 static key,
walks the control plane's device-code flow, and writes the credential and key into
`~/.config/yuke` for the client and daemon to share.

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
import relay "src:relay"

import curl "libs:bindings/curl"

// Control-plane base URL when neither `--cloud` nor `YUKE_CLOUD_URL` is set. The yuke-cloud dev
// server listens here; a hosted deployment overrides it.
DEFAULT_CLOUD_URL :: "http://localhost:3000"

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
    force: bool,
    name:  string,
    cloud: string,
}

// The `login` subcommand: enroll this device and persist its identity.
login_run :: proc() {
    opts, args_ok := login_args_parse(os.args[2:])
    if !args_ok {
        os.exit(2)
    }

    dir := paths.config_dir()
    if dir == "" {
        fmt.eprintln("yuke login: no config directory could be resolved")
        os.exit(1)
    }

    if !opts.force {
        existing, ierr := relay.identity_load(dir)
        if ierr == .None {
            fmt.printfln(
                "already enrolled as %s (relay %s); pass --force to re-enroll",
                existing.device_id,
                existing.relay_url,
            )
            relay.identity_destroy(&existing)

            return
        }

        if ierr != .Absent {
            fmt.eprintfln("yuke login: existing identity is unreadable (%v); pass --force to overwrite", ierr)
            os.exit(1)
        }
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
    start_body, enc_err := relay.enroll_start_encode(opts.name, ODIN_OS_STRING, pub_bytes[:], context.temp_allocator)
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

        if time.now()._nsec >= deadline._nsec {
            fmt.eprintln("yuke login: enrollment expired before approval; run `yuke login` again")
            os.exit(1)
        }

        pstatus, pbody, pok := cloud_post(&client, poll_url, poll_body, context.allocator)
        if !pok {
            // A transient network error mid-poll is not fatal; keep waiting for approval.
            continue
        }

        outcome, cred, _ := relay.enroll_poll_decode(pstatus, pbody, context.allocator)
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
            id := relay.Identity {
                device_id  = cred.device_id,
                credential = cred.credential,
                relay_url  = cred.relay_url,
                static_key = static_key,
                allocator  = context.allocator,
            }

            save_err := relay.identity_save(dir, &id, context.temp_allocator)
            if save_err != .None {
                relay.identity_destroy(&id)
                fmt.eprintfln("yuke login: could not write the identity to %s: %v", dir, save_err)
                os.exit(1)
            }

            fmt.printfln("Enrolled as %s (relay %s).", cred.device_id, cred.relay_url)
            relay.identity_destroy(&id)

            return
        }
    }
}

// Parse `yuke login` flags: `--force`, `--name <n>`/`--name=<n>`, `--cloud <url>`/`--cloud=<url>`.
// `name` defaults to `$HOSTNAME` (then a fixed fallback); `cloud` to `$YUKE_CLOUD_URL` or the dev
// default. Returns ok=false on an unknown flag or a missing value, having reported it.
@(private = "file")
login_args_parse :: proc(args: []string) -> (opts: Login_Options, ok: bool) {
    opts.cloud = login_default_cloud()
    opts.name = login_default_name()

    i := 0
    for i < len(args) {
        arg := args[i]

        switch {
        case arg == "--force":
            opts.force = true

        case arg == "--name":
            i += 1
            if i >= len(args) {
                fmt.eprintln("yuke login: --name needs a value")

                return {}, false
            }

            opts.name = args[i]

        case arg == "--cloud":
            i += 1
            if i >= len(args) {
                fmt.eprintln("yuke login: --cloud needs a value")

                return {}, false
            }

            opts.cloud = args[i]

        case strings.has_prefix(arg, "--name="):
            opts.name = arg[len("--name="):]

        case strings.has_prefix(arg, "--cloud="):
            opts.cloud = arg[len("--cloud="):]

        case:
            fmt.eprintfln("yuke login: unknown option %q", arg)

            return {}, false
        }

        i += 1
    }

    if opts.name == "" {
        opts.name = "yuke-device"
    }

    return opts, true
}

// The control-plane base URL: `$YUKE_CLOUD_URL` when set and non-empty, else the dev default.
@(private = "file")
login_default_cloud :: proc() -> string {
    if v, set := os.lookup_env(CLOUD_URL_ENV, context.allocator); set && v != "" {
        return v
    }

    return DEFAULT_CLOUD_URL
}

// The default device name: `$HOSTNAME` when set, else empty (the caller supplies a fallback).
@(private = "file")
login_default_name :: proc() -> string {
    if v, set := os.lookup_env("HOSTNAME", context.allocator); set && v != "" {
        return v
    }

    return ""
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
