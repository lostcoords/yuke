# http

An HTTP/1.1 client for the yuke coding agent. It uses hyper on tokio, and rustls with the aws-lc-rs provider.

- `Client::send` sends one request and returns the response at its head. The body streams.
- After its body, a connection waits up to 60 seconds for the next request to its host. A body dropped before the
  whole response arrived closes its connection.
- The client follows no redirect and decodes no `content-encoding`. The caller decides both.
- The client owns the framing headers. It sets `host` and `content-length`, and it removes `transfer-encoding`.
- It adds its `user-agent` when the request has none. `Client::new` takes the value as a `HeaderValue`.
- Each `Request` has its own `idle_timeout` and `deadline`. `Request::new` sets neither, so nothing bounds the wait.
  One client serves the whole process, and each caller sets the bounds of its requests.

## Cargo features

| Feature | Default | Provides |
| --- | --- | --- |
| `testing` | Disabled | `testing`: a loopback server for the tests of other crates. |
