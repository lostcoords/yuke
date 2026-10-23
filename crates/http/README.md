# http

An HTTP/1.1 client for the yuke coding agent. It uses hyper on tokio, and rustls with the aws-lc-rs provider.

- `Client::send` sends one request on a new connection and returns the response at its head. The body streams.
- The client follows no redirect and decodes no `content-encoding`. The caller decides both.
- The client owns the framing headers. It sets `host`, `connection: close`, and `content-length`, and it removes
  `transfer-encoding`.
- It adds its `user-agent` when the request has none.
- `ClientOptions::new` sets an idle timeout of 300 seconds. `None` sets no bound.

## Cargo features

| Feature | Default | Provides |
| --- | --- | --- |
| `testing` | Disabled | `testing`: a loopback server for the tests of other crates. |
