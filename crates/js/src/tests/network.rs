//! The global `fetch` against loopback servers of `yuke_http::testing`: the request on the wire, the response, the
//! redirects, the failures, and the aborts.

use std::time::Duration;

use yuke_http::testing::{Server, listen};

use rquickjs::Ctx;

use super::{evaluate, folder, run, start};
use crate::Runtime;

/// The JavaScript of a function `failure(promise)` that gives `name:code` of the rejection of `promise`, or
/// `fulfilled`. The code is the code of the cause, or `none`.
const FAILURE: &str = "const failure = (promise) => promise.then(() => 'fulfilled',
       (error) => `${error.name}:${error.cause?.code ?? 'none'}`);";

/// Run `body` in a new runtime, collect the garbage, and keep the runtime while each of `servers` ends. Give servers
/// that wait for a close of the client, so each end proves a close that `fetch` made, not one of the shutdown.
async fn run_while_servers_end(
    name: &str,
    body: &str,
    servers: Vec<tokio::task::JoinHandle<yuke_http::testing::Seen>>,
) -> String {
    let folder = folder(name);
    let (runtime, _reports): (Runtime, _) = start(&folder).await;
    let text = tokio::time::timeout(Duration::from_secs(5), evaluate::<String>(&runtime, body))
        .await
        .unwrap()
        .unwrap();
    runtime
        .caller
        .run(async |ctx: Ctx<'_>, _registry| {
            ctx.run_gc();
            Ok(())
        })
        .await
        .unwrap();
    // The turn runs the finalization callbacks that the collection queued.
    evaluate::<()>(&runtime, "await new Promise((resolve) => setTimeout(resolve, 0));")
        .await
        .unwrap();
    for server in servers {
        tokio::time::timeout(Duration::from_secs(5), server)
            .await
            .unwrap()
            .unwrap();
    }
    drop(runtime);
    text
}

/// Leak `text`, for a `location` header with a port: the server takes static header values.
fn leak(text: String) -> &'static str {
    Box::leak(text.into_boxed_str())
}

#[tokio::test]
async fn a_fetch_sends_the_request_and_reads_the_response() {
    let (port, server) = listen(Server {
        status: 201,
        body: b"hello".to_vec(),
        headers: vec![("x-a", "1")],
        ..Server::default()
    })
    .await;

    let text = run::<String>(
        "a_fetch_sends_the_request_and_reads_the_response",
        &format!(
            "const response = await fetch('http://127.0.0.1:{port}/p?q=1#part', {{
               method: 'POST', headers: {{ 'x-b': '2' }}, body: 'data',
             }});
             return [response.status, response.statusText, response.ok, response.type, response.url,
               response.redirected, response.headers.get('x-a'), await response.text()].join(' ');"
        ),
    )
    .await;
    let seen = server.await.unwrap();

    assert_eq!(
        text,
        format!("201 Created true basic http://127.0.0.1:{port}/p?q=1 false 1 hello")
    );
    assert_eq!((seen.method.as_str(), seen.target.as_str()), ("POST", "/p?q=1"));
    assert_eq!(seen.values("x-b"), ["2"]);
    assert_eq!(seen.values("content-type"), ["text/plain;charset=UTF-8"]);
    assert_eq!(seen.values("accept"), ["*/*"]);
    assert_eq!(seen.values("accept-encoding"), ["identity"]);
    assert_eq!(seen.values("user-agent"), ["yuke-js-test"]);
    assert_eq!(seen.body, b"data");
}

#[tokio::test]
async fn the_header_list_of_a_headers_init_reaches_the_wire_as_it_is() {
    let (port, server) = listen(Server {
        status: 200,
        ..Server::default()
    })
    .await;

    run::<()>(
        "the_header_list_of_a_headers_init_reaches_the_wire_as_it_is",
        &format!(
            "const headers = new Headers();
             headers.append('x-test', 'a');
             headers.append('X-Test', 'b');
             headers.append('accept-encoding', 'gzip');
             await (await fetch('http://127.0.0.1:{port}/', {{ headers }})).text();"
        ),
    )
    .await;
    let seen = server.await.unwrap();

    assert_eq!(seen.values("x-test"), ["a", "b"]);
    assert_eq!(seen.values("accept-encoding"), ["gzip"]);
}

#[tokio::test]
async fn a_redirect_to_another_origin_drops_the_authorization() {
    let (target, last) = listen(Server {
        status: 200,
        body: b"final".to_vec(),
        ..Server::default()
    })
    .await;
    let (port, first) = listen(Server {
        status: 302,
        headers: vec![("location", leak(format!("http://127.0.0.1:{target}/next")))],
        ..Server::default()
    })
    .await;

    let text = run::<String>(
        "a_redirect_to_another_origin_drops_the_authorization",
        &format!(
            "const response = await fetch('http://127.0.0.1:{port}/', {{
               headers: {{ authorization: 'secret', 'x-keep': '1' }},
             }});
             return [response.redirected, response.url, await response.text()].join(' ');"
        ),
    )
    .await;
    let (first, last) = (first.await.unwrap(), last.await.unwrap());

    assert_eq!(text, format!("true http://127.0.0.1:{target}/next final"));
    assert_eq!(first.values("authorization"), ["secret"]);
    assert_eq!(last.values("authorization"), Vec::<&str>::new());
    assert_eq!(last.values("x-keep"), ["1"]);
}

#[tokio::test]
async fn a_303_turns_a_post_into_a_get_without_its_body_and_a_307_keeps_both() {
    for (status, method, body, content_type) in [(303, "GET", "", None), (307, "POST", "x", Some("text/x"))] {
        let (target, last) = listen(Server {
            status: 200,
            ..Server::default()
        })
        .await;
        let (port, _first) = listen(Server {
            status,
            headers: vec![("location", leak(format!("http://127.0.0.1:{target}/")))],
            ..Server::default()
        })
        .await;

        run::<()>(
            "a_303_turns_a_post_into_a_get_without_its_body_and_a_307_keeps_both",
            &format!(
                "await (await fetch('http://127.0.0.1:{port}/', {{
                   method: 'POST', body: 'x', headers: {{ 'content-type': 'text/x', 'x-keep': '1' }},
                 }})).text();"
            ),
        )
        .await;
        let last = last.await.unwrap();

        assert_eq!(last.method, method, "status {status}");
        assert_eq!(last.body, body.as_bytes(), "status {status}");
        assert_eq!(
            last.values("content-type").first().copied(),
            content_type,
            "status {status}"
        );
        assert_eq!(last.values("x-keep"), ["1"], "status {status}");
    }
}

#[tokio::test]
async fn a_manual_redirect_gives_the_redirect_and_an_error_redirect_rejects() {
    let mut ports = Vec::new();
    for headers in [
        vec![("location", "/elsewhere")],
        vec![("location", "/elsewhere")],
        vec![("location", "mailto:someone@example.com")],
        vec![("location", "/a"), ("location", "/b")],
    ] {
        let (port, _server) = listen(Server {
            status: 302,
            headers,
            ..Server::default()
        })
        .await;
        ports.push(port);
    }
    let [manual, error, scheme, twice] = ports[..] else {
        unreachable!()
    };

    let text = run::<String>(
        "a_manual_redirect_gives_the_redirect_and_an_error_redirect_rejects",
        &format!(
            "{FAILURE}
             const response = await fetch('http://127.0.0.1:{manual}/', {{ redirect: 'manual' }});
             return [response.status, response.headers.get('location'), response.redirected,
               await failure(fetch('http://127.0.0.1:{error}/', {{ redirect: 'error' }})),
               await failure(fetch('http://127.0.0.1:{scheme}/')),
               await failure(fetch('http://127.0.0.1:{twice}/'))].join(' ');"
        ),
    )
    .await;

    assert_eq!(
        text,
        "302 /elsewhere false TypeError:redirect TypeError:redirect TypeError:redirect"
    );
}

#[tokio::test]
async fn a_fetch_follows_at_most_twenty_redirects() {
    // Each server redirects to the one before it, so the first request starts a chain of 21 redirects.
    let mut port = listen(Server {
        status: 200,
        ..Server::default()
    })
    .await
    .0;
    for _ in 0..21 {
        let location = leak(format!("http://127.0.0.1:{port}/"));
        port = listen(Server {
            status: 301,
            headers: vec![("location", location)],
            ..Server::default()
        })
        .await
        .0;
    }

    let text = run::<String>(
        "a_fetch_follows_at_most_twenty_redirects",
        &format!(
            "{FAILURE}
             return failure(fetch('http://127.0.0.1:{port}/'));"
        ),
    )
    .await;

    assert_eq!(text, "TypeError:redirect");
}

#[tokio::test]
async fn a_network_failure_rejects_with_a_type_error_that_names_its_cause() {
    let closed = {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        listener.local_addr().unwrap().port()
    };
    let (malformed, _server) = listen(Server {
        raw_response: Some(b"not http\r\n\r\n"),
        ..Server::default()
    })
    .await;

    let text = run::<String>(
        "a_network_failure_rejects_with_a_type_error_that_names_its_cause",
        &format!(
            "{FAILURE}
             const message = await fetch('http://127.0.0.1:{closed}/').catch((error) => error.message);
             return [message, await failure(fetch('http://127.0.0.1:{closed}/')),
               await failure(fetch('http://127.0.0.1:{malformed}/')),
               await failure(fetch('ftp://127.0.0.1/'))].join(' ');"
        ),
    )
    .await;

    assert_eq!(
        text,
        "fetch failed TypeError:connect_failed TypeError:malformed_response TypeError:bad_url"
    );
}

#[tokio::test]
async fn an_abort_rejects_the_fetch_and_errors_the_body_with_the_reason() {
    let (silent, waiting) = listen(Server {
        silent: true,
        ..Server::default()
    })
    .await;
    let (stalled, streaming) = listen(Server {
        status: 200,
        body: b"a".to_vec(),
        stall: true,
        ..Server::default()
    })
    .await;

    let text = run_while_servers_end(
        "an_abort_rejects_the_fetch_and_errors_the_body_with_the_reason",
        &format!(
            "const reason = (promise) => promise.then(() => 'fulfilled', (error) => String(error));
             const before = new AbortController();
             before.abort('early');
             const head = new AbortController();
             const pending = reason(fetch('http://127.0.0.1:{silent}/', {{ signal: head.signal }}));
             setTimeout(() => head.abort('head'), 20);
             const body = new AbortController();
             const response = await fetch('http://127.0.0.1:{stalled}/', {{ signal: body.signal }});
             const reader = response.body.getReader();
             const first = new TextDecoder().decode((await reader.read()).value);
             const next = reason(reader.read());
             // One timer turn starts the second read on the network, so the abort stops a read in flight.
             await new Promise((resolve) => setTimeout(resolve, 10));
             body.abort('body');
             return [await reason(fetch('http://127.0.0.1:{silent}/', {{ signal: before.signal }})), await pending,
               first, await next, await reason(reader.closed)].join(' ');"
        ),
        // The two network aborts closed their connections, so both servers see the close and end.
        vec![waiting, streaming],
    )
    .await;

    assert_eq!(text, "early head a body body");
}

#[tokio::test]
async fn a_cancel_of_the_body_stops_the_read_and_closes_the_connection() {
    let (port, server) = listen(Server {
        status: 200,
        body: b"a".to_vec(),
        stall: true,
        ..Server::default()
    })
    .await;

    let text = run_while_servers_end(
        "a_cancel_of_the_body_stops_the_read_and_closes_the_connection",
        &format!(
            "const response = await fetch('http://127.0.0.1:{port}/');
             const reader = response.body.getReader();
             await reader.read();
             const pending = reader.read();
             // One timer turn starts the second read on the network, so the cancel stops a read in flight.
             await new Promise((resolve) => setTimeout(resolve, 10));
             await reader.cancel();
             return `${{(await pending).done}} ${{response.bodyUsed}}`;"
        ),
        vec![server],
    )
    .await;

    assert_eq!(text, "true true");
}

#[tokio::test]
async fn an_unread_body_closes_its_connection_although_its_signal_lives() {
    let (port, server) = listen(Server {
        status: 200,
        body: b"a".to_vec(),
        stall: true,
        ..Server::default()
    })
    .await;

    let text = run_while_servers_end(
        "an_unread_body_closes_its_connection_although_its_signal_lives",
        &format!(
            "globalThis.controller = new AbortController();
             const response = await fetch('http://127.0.0.1:{port}/', {{ signal: controller.signal }});
             return String(response.status);"
        ),
        vec![server],
    )
    .await;

    assert_eq!(text, "200");
}

#[tokio::test]
async fn a_head_request_and_a_null_body_status_give_no_body() {
    let mut ports = Vec::new();
    for status in [200, 204] {
        ports.push(
            listen(Server {
                status,
                ..Server::default()
            })
            .await
            .0,
        );
    }
    let [head, empty] = ports[..] else { unreachable!() };

    let text = run::<String>(
        "a_head_request_and_a_null_body_status_give_no_body",
        &format!(
            "const responses = [await fetch('http://127.0.0.1:{head}/', {{ method: 'HEAD' }}),
               await fetch('http://127.0.0.1:{empty}/')];
             return responses.map((response) => `${{response.status}}:${{response.body}}`).join(' ');"
        ),
    )
    .await;

    assert_eq!(text, "200:null 204:null");
}

#[tokio::test]
async fn a_fetch_of_a_request_uses_its_body() {
    let (port, server) = listen(Server {
        status: 200,
        ..Server::default()
    })
    .await;

    let text = run::<String>(
        "a_fetch_of_a_request_uses_its_body",
        &format!(
            "const request = new Request('http://127.0.0.1:{port}/', {{ method: 'PUT', body: 'sent' }});
             await (await fetch(request)).text();
             const again = await fetch(request).then(() => 'fulfilled', (error) => error.name);
             return `${{request.bodyUsed}} ${{again}}`;"
        ),
    )
    .await;
    let seen = server.await.unwrap();

    assert_eq!(text, "true TypeError");
    assert_eq!(
        (seen.method.as_str(), seen.body.as_slice()),
        ("PUT", b"sent".as_slice())
    );
}
