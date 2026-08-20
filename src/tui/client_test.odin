package tui

import "core:nbio"
import "core:strings"
import "core:testing"

import qjs "libs:bindings/quickjs"
import "src:js"
import "src:term"

@(private = "file")
client_test_result :: proc(t: ^testing.T, h: ^Host) -> string {
    global := qjs.global_object(h.js.ctx)
    defer qjs.free_value(h.js.ctx, global)

    value := qjs.get_property(h.js.ctx, global, "result")
    defer qjs.free_value(h.js.ctx, value)

    result, ok := qjs.to_string(h.js.ctx, value)
    if !testing.expect(t, ok, "client test result should be readable") do return ""

    defer qjs.free_string(h.js.ctx, result)

    return strings.clone(result, context.temp_allocator)
}

@(private = "file")
client_test_host_init :: proc(t: ^testing.T, h: ^Host) -> bool {
    h.allocator = context.allocator
    modules := [1]js.Module{client_module()}

    return testing.expect_value(
        t,
        js.init(&h.js, {modules = modules[:], user = h, resolve = host_resolve, allocator = context.allocator}),
        js.Error.None,
    )
}

@(test)
test_client_script_module_loads :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !client_test_host_init(t, &h) do return

    defer js.destroy(&h.js)

    source := `
        import { ClientError, RpcError, connectionState } from "yuke:client";
        globalThis.result = [ClientError.name, RpcError.name, connectionState("local")].join(":");
    `
    testing.expect(t, js.eval_module(&h.js, "test:client-load", source, context.allocator))
    testing.expect_value(t, client_test_result(t, &h), "ClientError:RpcError:disconnected")
}

@(test)
test_client_script_request_rejects_when_disconnected :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !client_test_host_init(t, &h) do return

    defer js.destroy(&h.js)

    source := `
        import { sessionList } from "yuke:client";
        try {
          await sessionList("local");
          globalThis.result = "resolved";
        } catch (error) {
          globalThis.result = error.code;
        }
    `
    testing.expect(t, js.eval_module(&h.js, "test:client-disconnected", source, context.allocator))
    testing.expect_value(t, client_test_result(t, &h), "not_ready")
}

@(test)
test_client_shutdown_reaction_cannot_start_native_work :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !client_test_host_init(t, &h) do return

    defer js.destroy(&h.js)

    drive := term.Drive {
        loop = nbio.current_thread_event_loop(),
    }
    h.drive = &drive

    job, closing := client_promise_new(&h)
    if !testing.expect(t, job != nil, "closing promise should allocate") do return

    global := qjs.global_object(h.js.ctx)
    defer qjs.free_value(h.js.ctx, global)
    testing.expect(t, qjs.set_property(h.js.ctx, global, "closing", closing), "closing promise should install")

    source := `
        import { connect, sessionList } from "yuke:client";
        globalThis.closing.catch(() => {
          const failures = [];
          try {
            connect({ port: 1 });
            failures.push("connect-started");
          } catch (error) {
            failures.push(error.message);
          }
          try {
            sessionList("local");
            failures.push("request-started");
          } catch (error) {
            failures.push(error.message);
          }
          globalThis.result = failures.join(":");
        });
    `
    testing.expect(t, js.eval_module(&h.js, "test:client-shutdown-reaction", source, context.allocator))

    h.done = true
    client_promise_reject(job, "connection_closed", true)

    testing.expect_value(
        t,
        client_test_result(t, &h),
        "yuke:client host is shutting down:yuke:client host is shutting down",
    )
    testing.expect(t, len(h.conns) == 0, "shutdown reaction must not create a daemon connection")
    testing.expect_value(t, h.js.pending, 0)
}

@(test)
test_request_unknown_key_is_not_ready :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !client_test_host_init(t, &h) do return

    defer js.destroy(&h.js)

    source := `
        import { sessionList } from "yuke:client";
        try {
          await sessionList("remote:x");
          globalThis.result = "resolved";
        } catch (error) {
          globalThis.result = error.code;
        }
    `
    testing.expect(t, js.eval_module(&h.js, "test:client-unknown-key", source, context.allocator))
    testing.expect_value(t, client_test_result(t, &h), "not_ready")
}

@(test)
test_connect_same_key_throws :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !client_test_host_init(t, &h) do return

    defer js.destroy(&h.js)
    defer conns_free_unopened(&h)

    conn, ok := conn_slot_new(&h, CONN_LOCAL)
    if !testing.expect(t, ok, "same-key test needs a slot") do return

    conn.live = true
    conn.client.state = .Ready

    source := `
        import { connect } from "yuke:client";
        try {
          connect({ port: 1 });
          globalThis.result = "started";
        } catch (error) {
          globalThis.result = error.message;
        }
    `
    testing.expect(t, js.eval_module(&h.js, "test:client-same-key", source, context.allocator))
    testing.expect_value(t, client_test_result(t, &h), "a connection for this key already exists")
}

@(test)
test_connections_lists_live_slots :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !client_test_host_init(t, &h) do return

    defer js.destroy(&h.js)
    defer conns_free_unopened(&h)

    conn, ok := conn_slot_new(&h, CONN_LOCAL)
    if !testing.expect(t, ok, "connections test needs a slot") do return

    conn.live = true
    conn.client.state = .Ready

    source := `
        import { connections } from "yuke:client";
        const list = connections();
        globalThis.result = list.map((c) => c.key + ":" + c.state).join(",");
    `
    testing.expect(t, js.eval_module(&h.js, "test:client-connections", source, context.allocator))
    testing.expect_value(t, client_test_result(t, &h), "local:ready")
}

@(test)
test_devices_empty_when_not_enrolled :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !client_test_host_init(t, &h) do return

    defer js.destroy(&h.js)

    source := `
        import { devices } from "yuke:client";
        const list = await devices();
        globalThis.result = Array.isArray(list) && list.length === 0 ? "empty" : "nope";
    `
    testing.expect(t, js.eval_module(&h.js, "test:devices-unenrolled", source, context.allocator))
    testing.expect_value(t, client_test_result(t, &h), "empty")
}

@(test)
test_connect_duplicate_remote_throws :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !client_test_host_init(t, &h) do return

    defer js.destroy(&h.js)
    defer {
        for rc in h.remotes {
            delete(rc.device, h.allocator)
            delete(rc.device_id, h.allocator)
            delete(rc.name, h.allocator)
            free(rc, h.allocator)
        }

        delete(h.remotes)
        h.remotes = {}
    }

    rc := new(Remote_Connect, h.allocator)
    rc.host = &h
    rc.device = strings.clone("dev-a", h.allocator)
    append(&h.remotes, rc)

    source := `
        import { connect } from "yuke:client";
        try {
          connect({ remote: true, device: "dev-a" });
          globalThis.result = "started";
        } catch (error) {
          globalThis.result = error.message;
        }
    `
    testing.expect(t, js.eval_module(&h.js, "test:client-dup-remote", source, context.allocator))
    testing.expect_value(t, client_test_result(t, &h), "a connection for this key already exists")
}

@(test)
test_connections_lists_inflight_remotes :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !client_test_host_init(t, &h) do return

    defer js.destroy(&h.js)
    defer {
        for rc in h.remotes {
            delete(rc.device, h.allocator)
            delete(rc.device_id, h.allocator)
            delete(rc.name, h.allocator)
            free(rc, h.allocator)
        }

        delete(h.remotes)
        h.remotes = {}
    }

    a := new(Remote_Connect, h.allocator)
    a.host = &h
    a.device = strings.clone("aaa", h.allocator)
    a.device_id = strings.clone("aaa", h.allocator)
    append(&h.remotes, a)
    b := new(Remote_Connect, h.allocator)
    b.host = &h
    b.device = strings.clone("bbb", h.allocator)
    b.device_id = strings.clone("bbb", h.allocator)
    b.name = strings.clone("Office", h.allocator)
    append(&h.remotes, b)

    source := `
        import { connections } from "yuke:client";
        globalThis.result = connections().map((c) => c.key + ":" + c.state + ":" + c.deviceId + ":" + c.name).join(",");
    `
    testing.expect(t, js.eval_module(&h.js, "test:client-inflight-remotes", source, context.allocator))
    testing.expect_value(t, client_test_result(t, &h), "remote:aaa:connecting:aaa:,remote:bbb:connecting:bbb:Office")
}
