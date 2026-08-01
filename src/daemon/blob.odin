package daemon

import "base:runtime"
import "core:crypto"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import http_server "libs:http/server"
import "libs:offload"

// Hex length of the `/blob/*` capture, which renders a `wire.Media_Blob.hash` digest.
BLOB_HASH_HEX_LEN :: sha2.DIGEST_SIZE_256 * 2

// Temp-name prefix for an in-flight blob upload under `<blob_dir>`. A per-request
// random nonce follows so concurrent uploads of the same hash never share a temp file.
BLOB_TEMP_PREFIX :: ".upload."

// How stale an upload temp must be before a boot sweep treats it as crash residue
// rather than a slow in-flight upload that merely looks old.
UPLOAD_TEMP_GRACE :: 1 * time.Hour

// The store is private to the daemon: HTTP reads need the bearer token, a local reader
// does not. `core:os` defaults to 0777/0666, so both modes are always passed.
BLOB_DIR_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Execute_User}
BLOB_FILE_PERMISSIONS :: os.Permissions{.Read_User, .Write_User}

// Workers publishing uploads. Each one spends its time inside `fsync` rather than
// competing for a core, and concurrent publishes are already bounded by the front door's
// connection cap, so a small count is enough.
BLOB_WORKER_COUNT :: 2

// What publishing an upload decided. Recorded on a worker thread, which can neither
// answer the request nor log, and acted on by the completion back on the loop.
Blob_Outcome :: enum {
    // Not yet finalized.
    Pending,

    // Body did not complete; the temp file was deleted and nobody is owed an answer.
    Discarded,

    // Published under its content-addressed name.
    Stored,

    // Another upload of the same content won the race, or it was already stored.
    Already_Present,

    // The streamed digest did not match the digest in the URL.
    Mismatch,

    // A filesystem call failed; see `err`.
    Failed,
}

// Per-request blob-upload state. Owned across the async body receive and the offloaded
// publish, then freed by the completion. Every field a worker thread reads is owned here
// rather than borrowed, so the upload outlives its connection.
Blob_Upload :: struct {
    // Publishes off the reactor; carried here so submitting never allocates.
    task:        offload.Task(Blob_Upload),

    // Owning daemon, for the worker pool.
    daemon:      ^Daemon,

    // Connection to answer, if it is still there when the publish finishes. Zero when
    // the body never completed and no answer is owed.
    ticket:      http_server.Ticket,

    // Whether the body completed, so the temp file should be published rather than
    // discarded.
    publish:     bool,

    // What the publish decided, and the failure behind `.Failed`.
    outcome:     Blob_Outcome,
    err:         os.Error,

    // Allocator backing the owned strings and this struct.
    allocator:   mem.Allocator,

    // Owned final content-addressed path `<blob_dir>/<hash>`.
    final_path:  string,

    // Owned temp path streamed to, then atomically renamed to `final_path`.
    temp_path:   string,

    // Owned copy of the claimed 64-hex digest from the URL, for logging.
    claimed:     string,

    // The same digest decoded once on the loop, so the worker compares raw bytes instead
    // of encoding on a thread that must not allocate.
    claimed_raw: [sha2.DIGEST_SIZE_256]byte,

    // Incremental SHA-256 over the streamed body.
    sha:         sha2.Context_256,

    // Open temp file; nil once closed.
    file:        ^os.File,
}

// Fold one body chunk into the running digest and the temp file. A write error or
// shortfall aborts; the server then finalizes via the end callback with `ok = false`,
// which deletes the partial temp.
blob_upload_chunk :: proc(c: ^http_server.Conn, user_data: rawptr, chunk: []byte) -> bool {
    up := (^Blob_Upload)(user_data)
    assert(up != nil && up.file != nil, "blob chunk sink needs an open upload")
    assert(len(up.claimed) == BLOB_HASH_HEX_LEN, "blob upload lost its claimed digest")

    sha2.update(&up.sha, chunk)

    n, werr := os.write(up.file, chunk)
    if werr != nil || n != len(chunk) {
        log.errorf("daemon: blob temp write failed: %v", werr)
        return false
    }

    return true
}

// Hand the finished (or abandoned) upload to a worker. `fsync`, `rename`, and `unlink`
// have no nbio operation, so publishing on the reactor would stall every other
// connection; the whole finalize runs off it instead. The upload owns every path the
// worker reads, so it outlives this connection.
blob_upload_end :: proc(c: ^http_server.Conn, user_data: rawptr, ok: bool) {
    up := (^Blob_Upload)(user_data)
    assert(up != nil, "blob end callback needs upload state")
    assert(up.daemon != nil, "blob upload lost its daemon")
    assert(up.outcome == .Pending, "blob upload finalized twice")
    assert(up.file != nil, "blob upload reached its end callback with no temp file")

    up.publish = ok

    // Only a completed body has anyone to answer: `ok == false` also arrives from
    // connection teardown, where there is no longer a request in flight.
    if ok {
        up.ticket = c.ticket
        http_server.defer_response(c)
    }

    offload.submit(&up.daemon.blobs, up, blob_publish, blob_published)
}

// Worker thread. Touches only `up`, every path of which is an owned clone. Records an
// outcome rather than answering or logging: there may be no connection left to answer,
// and the logger belongs to the loop thread.
blob_publish :: proc(up: ^Blob_Upload) {
    assert(up.file != nil, "publish needs the temp file still open")
    assert(up.outcome == .Pending, "publish ran on a finalized upload")

    up.outcome = blob_finalize(up)
    assert(up.file == nil, "finalize left the temp file open")

    // The temp survives only when the rename turned it into the blob; every other outcome
    // leaves nothing behind for the boot sweep to find.
    if up.outcome != .Stored {
        os.remove(up.temp_path)
    }
}

// Close the temp file and decide the upload's fate, without touching the temp path: the
// single caller removes it for every outcome but `.Stored`. Sets `err` on a failure.
blob_finalize :: proc(up: ^Blob_Upload) -> Blob_Outcome {
    // Flush before the rename publishes a content-addressed name over bytes nothing
    // re-verifies on read. Narrows the power-loss window rather than closing it: darwin
    // needs `F_FULLFSYNC` for a media barrier. Directory durability is not forced.
    if up.publish {
        up.err = os.sync(up.file)
    }

    os.close(up.file)
    up.file = nil

    if !up.publish {
        return .Discarded
    }

    if up.err != nil {
        return .Failed
    }

    digest: [sha2.DIGEST_SIZE_256]byte
    sha2.final(&up.sha, digest[:])

    if digest != up.claimed_raw {
        return .Mismatch
    }

    // Content-addressed and idempotent: an already-present store makes the upload a
    // no-op, so drop the temp and report success without replacing the file.
    if os.exists(up.final_path) {
        return .Already_Present
    }

    if rerr := os.rename(up.temp_path, up.final_path); rerr != nil {
        // A concurrent upload of the same content may have published it between the
        // existence check and the rename; a now-present target is still success.
        if os.exists(up.final_path) {
            return .Already_Present
        }

        up.err = rerr
        return .Failed
    }

    return .Stored
}

// Loop thread. Answers the request when the connection is still there, and frees the
// upload either way: a publish that completed is correct whether or not anyone is left
// to hear about it. A mismatch, an already-present store, and a fresh store map to 400,
// 200, and 201. No bodies.
blob_published :: proc(up: ^Blob_Upload) {
    assert(up.outcome != .Pending, "publish completed without an outcome")
    assert(up.file == nil, "publish left the temp file open")
    defer blob_upload_free(up)

    switch up.outcome {
    case .Stored:
        log.debugf("daemon: stored blob %s", up.claimed)

    case .Failed:
        log.errorf("daemon: blob publish failed: %v", up.err)

    case .Pending, .Discarded, .Already_Present, .Mismatch:
    }

    c := http_server.conn_resolve(&up.daemon.front_door, up.ticket)
    if c == nil {
        return
    }

    switch up.outcome {
    case .Stored:
        http_server.respond_text(c, .Created, "")

    case .Already_Present:
        http_server.respond_text(c, .Ok, "")

    case .Mismatch:
        http_server.respond_text(c, .Bad_Request, "hash mismatch")

    case .Failed:
        http_server.respond_text(c, .Internal_Server_Error, "cannot store blob")

    case .Pending, .Discarded:
        assert(false, "an upload with no answer owed resolved a connection")
    }
}

// Build the owned final and temp paths for `hash` under `blob_dir`.
blob_paths :: proc(
    blob_dir: string,
    hash: string,
    allocator: mem.Allocator,
) -> (
    final_path: string,
    temp_path: string,
    ok: bool,
) {
    assert(len(blob_dir) > 0 && len(hash) == 64, "blob paths need a directory and a 64-hex name")

    nonce_raw: [8]byte
    crypto.rand_bytes(nonce_raw[:])
    nonce, herr := hex.encode(nonce_raw[:], allocator)
    if herr != nil {
        return "", "", false
    }
    defer delete(nonce, allocator)

    ferr: mem.Allocator_Error
    final_path, ferr = strings.concatenate({blob_dir, "/", hash}, allocator)
    if ferr != nil {
        return "", "", false
    }

    terr: mem.Allocator_Error
    temp_path, terr = strings.concatenate({blob_dir, "/", BLOB_TEMP_PREFIX, hash, ".", string(nonce)}, allocator)
    if terr != nil {
        delete(final_path, allocator)
        return "", "", false
    }

    return final_path, temp_path, true
}

// `make_directory_all` leaves an existing directory's mode alone, so a store predating
// `BLOB_DIR_PERMISSIONS` stays exposed. Reported, not tightened: narrowing an
// operator's directory is theirs to decide.
warn_exposed_blob_dir :: proc(blob_dir: string, allocator := context.allocator) {
    assert(len(blob_dir) > 0, "blob dir exposure check needs a configured directory")

    info, err := os.stat(blob_dir, allocator)
    if err != nil {
        return
    }
    defer os.file_info_delete(info, allocator)

    if exposed := info.mode & ~BLOB_DIR_PERMISSIONS; exposed != {} {
        log.warnf(
            "daemon: blob dir %s is reachable beyond its owner (%v); stored blobs bypass token auth on disk",
            blob_dir,
            exposed,
        )
    }
}

// Delete upload temp files (`.upload.<hash>.<nonce>`) under `blob_dir` older than
// `cutoff`: published blobs and other non-temp entries are never matched, and a temp
// at or after `cutoff` is left alone (an in-flight upload's temp is always fresh).
//
// Temp residue only accrues on a crash — a clean shutdown always renames or removes
// its temp — so a boot-only pass covers the threat model. Best-effort: an unreadable
// directory is not an error.
blob_sweep_temps :: proc(blob_dir: string, cutoff: time.Time) -> (removed: int) {
    assert(len(blob_dir) > 0, "blob temp sweep needs a configured blob directory")

    // The listing covers every entry in the store, so release it rather than retaining
    // it in the temp arena for the process lifetime.
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

    infos, err := os.read_all_directory_by_path(blob_dir, context.temp_allocator)
    if err != nil {
        return 0
    }

    for info in infos {
        if !strings.has_prefix(info.name, BLOB_TEMP_PREFIX) {
            continue
        }

        if time.diff(info.modification_time, cutoff) <= 0 {
            continue
        }

        path, aerr := strings.concatenate({blob_dir, "/", info.name}, context.temp_allocator)
        if aerr != nil {
            continue
        }

        if os.remove(path) == nil {
            removed += 1
        }
    }

    return removed
}

// Release the upload's owned strings and the `Blob_Upload`; the temp file must
// already be closed.
blob_upload_free :: proc(up: ^Blob_Upload) {
    assert(up != nil, "blob upload free needs state")
    assert(up.file == nil, "freeing an upload with its temp file still open")

    // Each is either the zero value or an owned clone, and `delete` no-ops on nil.
    delete(up.final_path, up.allocator)
    delete(up.temp_path, up.allocator)
    delete(up.claimed, up.allocator)

    free(up, up.allocator)
}
