/*
Package daemon binds the HTTP/WebSocket front door, relay transport, durable event
store, provider authentication, workspace reads, blob storage, and daemon script host
to one caller-owned `core:nbio` loop.

The front door serves `/ws` and `/blob/<sha256>` on one port. Origin/Host admission
runs before bearer authentication, and a credential must arrive through exactly one
of the Authorization header or `?token=`. An empty bearer token is permitted only on
a literal IPv4 loopback listener; non-loopback binds fail startup by default.

Each transport creates a `Conn` in `Awaiting_Initialize`. A valid `initialize` moves it
to `Ready`; malformed frames, binary frames, or methods in the wrong state close the
connection. Decoded wire values borrow the frame arena and are never retained without
cloning. Async completions resolve a monotonic `Conn_Ticket`, never a borrowed `^Conn`.

The pump is the only broadcast fan-out and sequence authority. Durable broadcasts are
validated and committed before delivery. Live droppable deltas alone may be shed;
other send failures close the connection. Resync folds the durable log and reads only
the config revisions referenced by its transcript page and open turn.

Provider auth keeps its store, curl client, callback listener, timers, and active work
in `Provider_Auth`. Codex and xAI support browser and device login; browser login is
local-transport only. Login, refresh, and credential mutation are single-flight; every
login has a deadline. Credential files are replaced atomically, and a terminal refresh
rejection removes the stale credential instead of retrying it forever.

Blob uploads stream into unique temporary files and are finalized on the worker pool.
After digest verification, a hard link publishes the content address atomically without
replacing an existing blob. Workspace describe/browse also run on workers; browse keeps
bounded candidates, uses an opaque name cursor, and both per-connection and global job
caps bound outstanding work.

The daemon owns one QuickJS runtime. The runtime is intentionally shared so later
session contexts can live beneath it; today startup evaluates `<script-root>/yuked.js`
and installs only the shared `yuke:fs` module. Filesystem host operations are offloaded,
path-contained after canonicalization, and counted until their promises settle.

Shutdown first stops admission and new JS operations, cancels reactor-owned auth/relay
work, and drains the front door, callback listener, workers, and JS completions. Only
then may `destroy` release stores, runtimes, credentials, arenas, and transport state.
Bearer values, provider tokens, relay credentials/tickets, and private key buffers must
never be logged and are explicitly wiped when their owner releases them.
*/

package daemon
