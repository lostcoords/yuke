package main

import "core:nbio"
import "core:strings"
import "core:testing"

import qjs "libs:bindings/quickjs"
import js "src:js"
import term "src:term"

@(private = "file")
client_test_result :: proc(t: ^testing.T, h: ^Host) -> string {
    global := qjs.global_object(h.js.ctx)
    defer qjs.free_value(h.js.ctx, global)

    value := qjs.get_property(h.js.ctx, global, "result")
    defer qjs.free_value(h.js.ctx, value)

    result, ok := qjs.to_string(h.js.ctx, value)
    if !testing.expect(t, ok, "client test result should be readable") {
        return ""
    }

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
    if !client_test_host_init(t, &h) {
        return
    }

    defer js.destroy(&h.js)

    source := `
        import { ClientError, RpcError, connectionState } from "yuke:client";
        globalThis.result = [ClientError.name, RpcError.name, connectionState()].join(":");
    `
    testing.expect(t, js.eval_module(&h.js, "test:client-load", source, context.allocator))
    testing.expect_value(t, client_test_result(t, &h), "ClientError:RpcError:disconnected")
}

@(test)
test_client_script_request_rejects_when_disconnected :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    h: Host
    if !client_test_host_init(t, &h) {
        return
    }

    defer js.destroy(&h.js)

    source := `
        import { sessionList } from "yuke:client";
        try {
          await sessionList();
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
    if !client_test_host_init(t, &h) {
        return
    }

    defer js.destroy(&h.js)

    drive := term.Drive {
        loop = nbio.current_thread_event_loop(),
    }
    h.drive = &drive

    job, closing := client_promise_new(&h)
    if !testing.expect(t, job != nil, "closing promise should allocate") {
        return
    }

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
            sessionList();
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
    testing.expect(t, !h.daemon.live, "shutdown reaction must not create a daemon connection")
    testing.expect_value(t, h.js.pending, 0)
}
