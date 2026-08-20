package main

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "libs:bindings/curl"

SEQUENTIAL :: 2000
CONCURRENT_TOTAL :: 2000
CONCURRENT_WINDOW :: 64
WAIT_MS :: 200
WAIT_ROUNDS :: 20
BODY_SIZE :: 64
WARMUP :: 16

Server :: struct {
    listener: net.TCP_Socket,
    port:     int,
    stop:     bool,
}

Run :: struct {
    client:    curl.Client,
    transfers: []curl.Transfer,
    url:       cstring,
    pending:   int,
    next:      int,
    total:     int,
    window:    int,
    ok:        int,
    err:       int,
    done:      bool,
}

main :: proc() {
    label := "local"
    if len(os.args) > 1 do label = os.args[1]

    server: Server
    if !server_start(&server) {
        fmt.eprintln("bench: listen failed")
        os.exit(1)
    }

    defer server_stop(&server)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    instant := fmt.ctprintf("http://127.0.0.1:%d/instant", server.port)
    delayed := fmt.ctprintf("http://127.0.0.1:%d/delay", server.port)

    warmup(loop, instant)

    seq_ms, seq_ok := bench_sequential(loop, instant, SEQUENTIAL)
    par_ms, par_ok := bench_concurrent(loop, instant, CONCURRENT_TOTAL, CONCURRENT_WINDOW)
    wait_ms, wait_ticks, wait_ok := bench_wait(loop, delayed, WAIT_ROUNDS)

    fmt.printf("label=%s\n", label)
    fmt.printf(
        "sequential n=%d ok=%d wall_ms=%.2f req_per_s=%.0f\n",
        SEQUENTIAL,
        seq_ok,
        seq_ms,
        1000.0 * f64(SEQUENTIAL) / seq_ms,
    )
    fmt.printf(
        "concurrent n=%d window=%d ok=%d wall_ms=%.2f req_per_s=%.0f\n",
        CONCURRENT_TOTAL,
        CONCURRENT_WINDOW,
        par_ok,
        par_ms,
        1000.0 * f64(CONCURRENT_TOTAL) / par_ms,
    )
    fmt.printf(
        "wait n=%d delay_ms=%d ok=%d wall_ms=%.2f ticks=%d ticks_per_wait=%.1f\n",
        WAIT_ROUNDS,
        WAIT_MS,
        wait_ok,
        wait_ms,
        wait_ticks,
        f64(wait_ticks) / f64(WAIT_ROUNDS),
    )
}

warmup :: proc(loop: ^nbio.Event_Loop, url: cstring) {
    _, _ = bench_sequential(loop, url, WARMUP)
}

bench_sequential :: proc(loop: ^nbio.Event_Loop, url: cstring, n: int) -> (wall_ms: f64, ok: int) {
    r: Run
    run_init(&r, loop, url, n, 1)
    defer run_destroy(&r)

    start := time.tick_now()
    run_fill(&r)
    nbio.run_until(&r.done)
    wall_ms = f64(time.tick_since(start)) / 1e6
    ok = r.ok

    return
}

bench_concurrent :: proc(loop: ^nbio.Event_Loop, url: cstring, n: int, window: int) -> (wall_ms: f64, ok: int) {
    r: Run
    run_init(&r, loop, url, n, window)
    defer run_destroy(&r)

    start := time.tick_now()
    run_fill(&r)
    nbio.run_until(&r.done)
    wall_ms = f64(time.tick_since(start)) / 1e6
    ok = r.ok

    return
}

bench_wait :: proc(loop: ^nbio.Event_Loop, url: cstring, n: int) -> (wall_ms: f64, ticks: int, ok: int) {
    r: Run
    run_init(&r, loop, url, n, 1)
    defer run_destroy(&r)

    start := time.tick_now()
    run_fill(&r)
    for !r.done {
        _ = nbio.tick(nbio.NO_TIMEOUT)
        ticks += 1
    }

    wall_ms = f64(time.tick_since(start)) / 1e6
    ok = r.ok

    return
}

run_init :: proc(r: ^Run, loop: ^nbio.Event_Loop, url: cstring, total: int, window: int) {
    r.url = url
    r.total = total
    r.window = window
    r.transfers = make([]curl.Transfer, total)
    if curl.client_init(&r.client, loop) != .None {
        fmt.eprintln("bench: client_init failed")
        os.exit(1)
    }
}

run_destroy :: proc(r: ^Run) {
    curl.client_destroy(&r.client)
    delete(r.transfers)
}

run_fill :: proc(r: ^Run) {
    for r.next < r.total && r.pending < r.window {
        req := curl.Request {
            url = r.url,
        }
        if curl.transfer_start(&r.transfers[r.next], &r.client, req, {on_done = run_on_done}, r) != .None {
            fmt.eprintln("bench: transfer_start failed")
            os.exit(1)
        }

        r.next += 1
        r.pending += 1
    }
}

run_on_done :: proc(user: rawptr, result: curl.Result) {
    r := (^Run)(user)
    r.pending -= 1
    if result.code == .Ok && result.status == 200 do r.ok += 1
    else do r.err += 1

    if r.next < r.total {
        run_fill(r)

        return
    }

    if r.pending == 0 do r.done = true
}

server_start :: proc(s: ^Server) -> bool {
    listener, err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
    if err != nil do return false

    endpoint, eerr := net.bound_endpoint(listener)
    if eerr != nil {
        net.close(listener)

        return false
    }

    s.listener = listener
    s.port = endpoint.port
    thread.create_and_start_with_poly_data(s, server_loop)

    return true
}

server_stop :: proc(s: ^Server) {
    sync.atomic_store(&s.stop, true)
    net.close(s.listener)
}

server_loop :: proc(s: ^Server) {
    for !sync.atomic_load(&s.stop) {
        conn, _, err := net.accept_tcp(s.listener)
        if err != nil do break

        server_handle(conn)
    }
}

server_handle :: proc(conn: net.TCP_Socket) {
    defer net.close(conn)

    buf: [1024]byte
    n, err := net.recv_tcp(conn, buf[:])
    if err != nil || n <= 0 do return

    req := string(buf[:n])
    if strings.contains(req, " /delay") do time.sleep(WAIT_MS * time.Millisecond)

    hdr :: "HTTP/1.1 200 OK\r\nContent-Length: 64\r\nConnection: close\r\n\r\n"
    #assert(BODY_SIZE == 64)
    _, _ = net.send_tcp(conn, transmute([]byte)string(hdr))

    payload: [BODY_SIZE]byte
    for i in 0 ..< BODY_SIZE {
        payload[i] = 'x'
    }

    _, _ = net.send_tcp(conn, payload[:])
}
