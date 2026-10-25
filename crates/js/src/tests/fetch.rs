//! The web classes of `yuke:internal/fetch`: `Request`, `Response`, and their body methods. Many cases follow the web
//! platform tests (WPT) of `fetch/api/request`, `fetch/api/response`, and `fetch/api/body`.

use super::{NAMES, run};

/// The JavaScript of a function `failure(promise)` that gives the name of the rejection of `promise`, or `fulfilled`.
const FAILURE: &str = "const failure = (promise) => promise.then(() => 'fulfilled', (error) => error.name);";

#[tokio::test]
async fn a_request_has_the_defaults_of_the_standard() {
    let text = run::<String>(
        "a_request_has_the_defaults_of_the_standard",
        "const request = new Request(new URL('https://a.example/x?q#f'));
         return [request.method, request.url, request.redirect, request.body, request.bodyUsed,
           request.signal instanceof AbortSignal, request.signal.aborted, request.headers instanceof Headers,
           [...request.headers].length].join(' ');",
    )
    .await;

    assert_eq!(text, "GET https://a.example/x?q#f follow  false true false true 0");
}

#[tokio::test]
async fn a_request_normalizes_the_method_and_refuses_bad_input() {
    let text = run::<String>(
        "a_request_normalizes_the_method_and_refuses_bad_input",
        &format!(
            "{NAMES}
             const url = 'https://a.example/';
             return [
               new Request(url, {{ method: 'post' }}).method,
               new Request(url, {{ method: 'patch' }}).method,
               names([
                 () => new Request(url, {{ method: 'connect' }}),
                 () => new Request(url, {{ method: 'bad method' }}),
                 () => new Request(url, {{ body: 'x' }}),
                 () => new Request(url, {{ method: 'HEAD', body: 'x' }}),
                 () => new Request('/relative'),
                 () => new Request('https://user:pw@a.example/'),
                 () => new Request(url, {{ redirect: 'sometimes' }}),
                 () => new Request(url, {{ signal: {{}} }}),
                 () => new Request(url, {{ method: 'POST', body: new ReadableStream() }}),
                 () => new Request(url, {{ method: 'POST', body: 'x', duplex: 'full' }}),
                 () => new Request(),
               ]),
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(
        text,
        "POST patch TypeError TypeError TypeError TypeError TypeError TypeError TypeError TypeError TypeError TypeError \
         TypeError"
    );
}

#[tokio::test]
async fn a_request_body_sets_its_content_type_and_reads_once() {
    let text = run::<String>(
        "a_request_body_sets_its_content_type_and_reads_once",
        &format!(
            "{FAILURE}
             const url = 'https://a.example/';
             const type = (body, headers) => new Request(url, {{ method: 'POST', body, headers }}).headers.get('content-type');
             class Params extends URLSearchParams {{ toString() {{ return 'wrong'; }} }}
             const request = new Request(url, {{ method: 'POST', body: 'hé' }});
             const text = await request.text();
             return [
               type('x'),
               type(new URLSearchParams('a=1')),
               type(new Uint8Array([1])),
               type('x', {{ 'content-type': 'application/json' }}),
               text,
               request.bodyUsed,
               await failure(request.text()),
               await new Request(url, {{ method: 'PUT', body: new URLSearchParams({{ a: 'b c' }}) }}).text(),
               await new Request(url, {{ method: 'PUT', body: new Params('a=1') }}).text(),
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(
        text,
        "text/plain;charset=UTF-8 application/x-www-form-urlencoded;charset=UTF-8  application/json hé true TypeError a=b+c a=1"
    );
}

#[tokio::test]
async fn a_request_from_a_request_copies_it_and_takes_its_body() {
    let text = run::<String>(
        "a_request_from_a_request_copies_it_and_takes_its_body",
        &format!(
            "{NAMES}
             {FAILURE}
             const original = new Request('https://a.example/', {{ method: 'POST', body: 'data', headers: {{ a: '1' }} }});
             const copy = new Request(original, {{ method: 'PUT' }});
             copy.headers.append('b', '2');
             return [
               copy.url, copy.method, original.method, original.headers.has('b'), copy.headers.get('a'),
               original.bodyUsed, await copy.text(), await failure(original.text()),
               names([() => new Request(original)]),
               new Request(new Request('https://a.example/', {{ redirect: 'manual' }})).redirect,
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(
        text,
        "https://a.example/ PUT POST false 1 true data TypeError TypeError manual"
    );
}

#[tokio::test]
async fn the_signal_of_a_request_follows_the_signal_of_its_init_and_its_input() {
    let text = run::<String>(
        "the_signal_of_a_request_follows_the_signal_of_its_init_and_its_input",
        "const controller = new AbortController();
         const request = new Request('https://a.example/', { signal: controller.signal });
         const copy = new Request(request);
         const unlinked = new Request(request, { signal: null });
         const before = request.signal.aborted;
         controller.abort('stop');
         return [before, request.signal === controller.signal, request.signal.reason, copy.signal.reason,
           unlinked.signal.aborted].join(' ');",
    )
    .await;

    assert_eq!(text, "false false stop stop false");
}

#[tokio::test]
async fn a_response_has_the_defaults_of_the_standard_and_takes_its_init() {
    let text = run::<String>(
        "a_response_has_the_defaults_of_the_standard_and_takes_its_init",
        "const plain = new Response();
         const made = new Response('hi', { status: 201, statusText: 'Created', headers: { 'x-a': '1' } });
         return [plain.status, plain.ok, JSON.stringify(plain.statusText), plain.type, JSON.stringify(plain.url),
           plain.redirected, plain.body, JSON.stringify(await plain.text()), made.status, made.statusText,
           made.headers.get('x-a'), made.headers.get('content-type'), await made.text()].join(' ');",
    )
    .await;

    assert_eq!(
        text,
        r#"200 true "" default "" false  "" 201 Created 1 text/plain;charset=UTF-8 hi"#
    );
}

#[tokio::test]
async fn a_response_checks_its_status_and_status_text() {
    let text = run::<String>(
        "a_response_checks_its_status_and_status_text",
        &format!(
            "{NAMES}
             return [
               names([
                 () => new Response(null, {{ status: 199 }}),
                 () => new Response(null, {{ status: 600 }}),
                 () => new Response(null, {{ statusText: 'a\\nb' }}),
                 () => new Response('x', {{ status: 204 }}),
                 () => new Response(null, {{ status: 1n }}),
               ]),
               new Response(null, {{ status: 65736 }}).status,
               new Response(null, {{ status: 204 }}).status,
               new Response(null, {{ status: 599 }}).ok,
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(
        text,
        "RangeError RangeError TypeError TypeError TypeError 200 204 false"
    );
}

#[tokio::test]
async fn the_body_methods_read_the_bytes_once() {
    let text = run::<String>(
        "the_body_methods_read_the_bytes_once",
        &format!(
            "{FAILURE}
             const bytes = new Uint8Array([0xef, 0xbb, 0xbf, 0x61, 0xff]);
             const json = await new Response('{{\"a\":[1]}}').json();
             const buffer = await new Response(bytes).arrayBuffer();
             const kept = new Response(bytes);
             bytes[3] = 0x62;
             const viewed = await new Response(bytes.subarray(3)).bytes();
             const used = new Response('x');
             await used.text();
             const locked = new Response('x');
             locked.body.getReader();
             const cancelled = new Response('x');
             await cancelled.body.cancel();
             return [
               JSON.stringify(json),
               buffer instanceof ArrayBuffer, buffer.byteLength, new Uint8Array(await kept.arrayBuffer())[3],
               JSON.stringify(await new Response(new Uint8Array([0xef, 0xbb, 0xbf, 0x61, 0xff])).text()),
               viewed instanceof Uint8Array, [...viewed].join(','),
               used.bodyUsed, await failure(used.text()), await failure(used.arrayBuffer()),
               locked.bodyUsed, await failure(locked.text()), cancelled.bodyUsed, await failure(cancelled.text()),
               await failure(new Response('{{').json()),
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(
        text,
        r#"{"a":[1]} true 5 97 "a�" true 98,255 true TypeError TypeError false TypeError true TypeError SyntaxError"#
    );
}

#[tokio::test]
async fn a_response_reads_a_stream_body_and_refuses_a_chunk_that_is_not_bytes() {
    let text = run::<String>(
        "a_response_reads_a_stream_body_and_refuses_a_chunk_that_is_not_bytes",
        &format!(
            "{NAMES}
             {FAILURE}
             const stream = (chunks) => new ReadableStream({{
               start(controller) {{ for (const chunk of chunks) controller.enqueue(chunk); controller.close(); }},
             }});
             const encoder = new TextEncoder();
             const body = stream([encoder.encode('a'), encoder.encode('b')]);
             // The source writes each chunk into one buffer, so the body must keep a copy of each chunk.
             const buffer = new Uint8Array(1);
             let pulls = 0;
             const reused = new ReadableStream({{
               pull(controller) {{
                 if (pulls === 2) controller.close();
                 else {{ buffer[0] = 0x61 + pulls++; controller.enqueue(buffer); }}
               }},
             }}, {{ highWaterMark: 0 }});
             const response = new Response(body);
             const locked = new ReadableStream();
             locked.getReader();
             return [
               response.body === body, response.headers.has('content-type'), await response.text(),
               await new Response(reused).text(),
               await failure(new Response(stream(['text'])).text()),
               names([() => new Response(locked)]),
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(text, "true false ab ab TypeError TypeError");
}

#[tokio::test]
async fn the_static_methods_make_an_error_a_redirect_and_json() {
    let text = run::<String>(
        "the_static_methods_make_an_error_a_redirect_and_json",
        &format!(
            "{NAMES}
             const error = Response.error();
             const redirect = Response.redirect('https://a.example/x', 307);
             const json = Response.json({{ a: 1 }}, {{ status: 201, headers: {{ 'content-type': 'text/x' }} }});
             return [
               error.type, error.status, error.ok, error.body,
               redirect.status, redirect.headers.get('location'), Response.redirect('https://a.example/').status,
               json.status, json.headers.get('content-type'), await json.text(),
               Response.json('x').headers.get('content-type'),
               names([
                 () => Response.redirect('https://a.example/', 200),
                 () => Response.redirect('/relative'),
                 () => Response.json(undefined),
                 () => Response.json({{ a: 1n }}),
               ]),
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(
        text,
        r#"error 0 false  307 https://a.example/x 302 201 text/x {"a":1} application/json RangeError TypeError TypeError TypeError"#
    );
}

#[tokio::test]
async fn a_member_refuses_a_value_of_another_class() {
    let text = run::<String>(
        "a_member_refuses_a_value_of_another_class",
        &format!(
            "{NAMES}
             {FAILURE}
             const getter = (type, name) => Object.getOwnPropertyDescriptor(type.prototype, name).get;
             return [
               names([
                 () => getter(Request, 'url').call({{}}),
                 () => getter(Response, 'body').call({{}}),
                 () => getter(Request, 'bodyUsed').call({{}}),
               ]),
               await failure(Response.prototype.text.call({{}})),
               await failure(Request.prototype.json.call(new Response('1'))),
               [new Request('https://a.example/'), new Response()].map((value) => Object.prototype.toString.call(value)),
               Object.keys(Response.prototype).includes('text'),
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(
        text,
        "TypeError TypeError TypeError TypeError TypeError [object Request],[object Response] true"
    );
}

#[tokio::test]
async fn the_arguments_convert_before_the_steps_run() {
    let text = run::<String>(
        "the_arguments_convert_before_the_steps_run",
        &format!(
            "{NAMES}
             const seen = [];
             const init = {{
               get body() {{ seen.push('body'); return null; }},
               get headers() {{ seen.push('headers'); return undefined; }},
               get method() {{ seen.push('method'); return undefined; }},
             }};
             const status = {{ valueOf() {{ seen.push('status'); return 301; }} }};
             return [
               names([() => new Request('/relative', init), () => Response.redirect('/relative', status)]),
               seen.join(','),
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(text, "TypeError TypeError body,headers,method,status");
}
