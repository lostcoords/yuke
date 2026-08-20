# 2026-08-16 — idle curl clients strand server-closed connections in CLOSE_WAIT

## Symptom

A long-lived `yuke daemon` accumulates half-dead outbound `:443` sockets stuck in `CLOSE_WAIT`.
Observed on the Mac daemon after ~75 min uptime, two of them, stable (not transient):

```
$ lsof -nP -p <yuked> -iTCP | grep -E '443'
yuke  16u  IPv6 ...:60236->[2606:4700:3035::ac43:85f2]:443 (CLOSE_WAIT)   # Cloudflare
yuke  22u  IPv6 ...:60239->[2606:4700:3031::6815:195b]:443 (ESTABLISHED)  # live relay ws link
yuke  24u  IPv6 ...:60249->[2600:140b:1c00:1e::1738:93]:443 (CLOSE_WAIT)  # CloudFront
```

The adjacent local ports (60236 / 60239 / 60249) show a startup burst of three outbound
connections. The middle one is the healthy WebSocket relay link; the two on either side are dead
one-shot curl connections.

`CLOSE_WAIT` means the peer sent FIN and the kernel is waiting for **our** process to `close()` the
fd. It never does, so the fd + a small socket buffer are held for the client's whole life.

## Cause

Two facts in the curl driver combine.

**1. Connection reuse is on and unbounded.** `Forbid_Reuse` exists in the FFI enum
(`libs/bindings/curl/c.odin:243`) but is never set, and no `MAXAGE_CONN` / `MAXLIFETIME_CONN` is set
either:

```
$ grep -rn "MAXAGE\|MAXLIFETIME\|FORBID_REUSE\|FRESH_CONNECT\|MAXCONNECTS" libs/bindings/curl src --glob '!*_test*'
libs/bindings/curl/c.odin:243:    Forbid_Reuse = OPTTYPE_LONG + 75,   # defined, never applied
(nothing else)
```

So every `curl.Client` runs libcurl's default: after a transfer finishes, its TCP+TLS connection is
parked in the multi handle's connection cache for reuse.

**2. The pump timer is disarmed while idle.** By design (`libs/bindings/curl/doc.odin:20-23`,
`client_sync_timer` at `libs/bindings/curl/curl.odin:287-302`) the `nbio` timer that calls
`curl_multi_perform` is armed on the first live transfer and disarmed when the last one ends — "an
idle client costs nothing."

The leak is the intersection:

1. A one-shot transfer completes; libcurl parks the connection in its cache.
2. Last transfer ends → pump timer disarmed → `curl_multi_perform` never runs again.
3. Cloudflare / CloudFront closes the idle keep-alive connection (~tens of seconds) → FIN →
   kernel moves the socket to `CLOSE_WAIT`.
4. libcurl's connection-cache maintenance only runs *inside* `multi_perform` / `socket_action`.
   With the timer disarmed it never fires, so libcurl never sees the FIN and never closes the fd.

The stranded fd is only reaped on that client's **next** transfer (libcurl detects and discards dead
cached connections on reuse) or on `client_destroy`.

### Which clients strand a socket

Any curl client that does one transfer and then goes idle. Matches the two observed sockets:

- `r.curl_client` — relay **ticket fetch** (`src/daemon/relay.odin:279`), Cloudflare control plane
  (`60236`). Only re-fetches on relay reconnect; while the link stays up it sits idle → stranded.
- `d.catalog_refresh.curl` — **catalog refresh** (`src/daemon/catalog_refresh_op.odin:52`),
  CloudFront (`60249`). One-shot / long interval.
- `d.provider_auth.curl` (`src/daemon/provider_auth.odin:296`) and the per-run provider client
  (`src/provider/turn.odin:182`) can strand one each the same way between uses.

Not implicated: the WebSocket relay link (`src/relay/link.odin`, `ws.client_*`) is a separate
subsystem and closes its fd via `ws.client_close`; the ESTABLISHED `60239` above is healthy.

## Severity

Low, but a genuine leak (inconsistent with the zero-technical-debt policy).

- **Bounded**, not unbounded growth: capped by libcurl's default `MAXCONNECTS` per multi handle (a
  few per client), so a handful of half-dead fds, never fd exhaustion under normal use.
- **Self-healing** on the next transfer of the same client, and on `client_destroy`.
- **Worse on awou**: every relay reconnect triggers a fresh ticket fetch, each leaving a
  `CLOSE_WAIT` that lingers until the *following* reconnect. A daemon that reconnects across network
  changes accumulates them faster than an idle one.

## Fix (proposed, not applied)

Preferred, matches the "idle client costs nothing" goal:

- Set `CURLOPT_FORBID_REUSE` on the infrequent one-shot clients (relay ticket fetch, catalog
  refresh, provider-auth). They don't benefit from keep-alive, and forbidding reuse makes libcurl
  close the connection the instant the transfer ends — no pooled fd to strand. One `setopt` per
  client.
- Leave the per-run provider client (`src/provider/turn.odin`) on reuse: it benefits from keep-alive
  within a turn and is destroyed at run end, which reaps its cache.

Alternatives (more machinery): drop the cache when a client goes idle
(`CURLMOPT_MAXCONNECTS = 0`, or one final `multi_perform` after the last transfer completes).
`MAXAGE_CONN` / `MAXLIFETIME_CONN` alone do **not** help — they are enforced inside `multi_perform`,
which is exactly what stops running when idle.
