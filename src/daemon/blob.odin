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

// What publishing an upload decided. Recorded on a worker thread, which can neither
// answer the request nor log, and acted on by the completion back on the loop.
Blob_Outcome :: enum {
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

// Per-request blob-upload state, owned across the async receive and offloaded publish.
// Every field a worker reads is owned here, not borrowed, so the upload outlives its connection.
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

    // What the publish decided, and the failure behind `.Failed`. Nil until the
    // worker finalizes the upload.
    outcome:     Maybe(Blob_Outcome),
    err:         os.Error,

    // Allocator backing the owned strings and this struct.
    allocator:   mem.Allocator,

    // Owned final content-addressed path `<blob_dir>/<hash>`.
    final_path:  string,

    // Owned temp path streamed to, then atomically linked to `final_path`.
    temp_path:   string,

    // The claimed 64-hex digest from the URL, copied inline for logging.
    claimed:     [BLOB_HASH_HEX_LEN]u8,

    // The same digest decoded once on the loop, so the worker compares raw bytes instead
    // of encoding on a thread that must not allocate.
    claimed_raw: [sha2.DIGEST_SIZE_256]byte,

    // Incremental SHA-256 over the streamed body.
    sha:         sha2.Context_256,

    // Open temp file; nil once closed.
    file:        ^os.File,
}

// Folds one body chunk into the digest and temp file. A write error or shortfall aborts;
// the server finalizes with `ok = false`, deleting the partial temp.
blob_upload_chunk :: proc(c: ^http_server.Conn, user_data: rawptr, chunk: []byte) -> bool {
    up := (^Blob_Upload)(user_data)
    assert(up != nil && up.file != nil, "blob chunk sink needs an open upload")

    sha2.update(&up.sha, chunk)

    n, werr := os.write(up.file, chunk)
    if werr != nil || n != len(chunk) {
        log.errorf("daemon: blob temp write failed: %v", werr)
        return false
    }

    return true
}

// Hands the finished (or abandoned) upload to a worker: `fsync`/`link`/`unlink` have no
// nbio operation, so finalizing on the reactor would stall every other connection.
blob_upload_end :: proc(c: ^http_server.Conn, user_data: rawptr, ok: bool) {
    up := (^Blob_Upload)(user_data)
    assert(up != nil, "blob end callback needs upload state")
    assert(up.daemon != nil, "blob upload lost its daemon")
    assert(up.outcome == nil, "blob upload finalized twice")
    assert(up.file != nil, "blob upload reached its end callback with no temp file")

    up.publish = ok

    // Only a completed body has anyone to answer: `ok == false` also arrives from
    // connection teardown, where there is no longer a request in flight.
    if ok {
        up.ticket = c.ticket
        http_server.defer_response(c)
    }

    offload.submit(&up.daemon.workers, up, blob_publish, blob_published)
}

// Worker thread. Records an outcome rather than answering or logging: there may be no
// connection left to answer, and the logger belongs to the loop thread.
blob_publish :: proc(up: ^Blob_Upload) {
    assert(up.file != nil, "publish needs the temp file still open")
    assert(up.outcome == nil, "publish ran on a finalized upload")

    outcome := blob_finalize(up)
    up.outcome = outcome
    assert(up.file == nil, "finalize left the temp file open")

    // A successful publish leaves the final hard link intact; every outcome can drop
    // the temporary name. A failed unlink is harmless crash residue for the boot sweep.
    os.remove(up.temp_path)
}

// Close the temp file and decide the upload's fate, without touching the temp path: the
// single caller removes it for every outcome but `.Stored`. Sets `err` on a failure.
blob_finalize :: proc(up: ^Blob_Upload) -> Blob_Outcome {
    // Flush before a hard link publishes the content-addressed name. Narrows the power-loss
    // window rather than closing it; darwin needs `F_FULLFSYNC` for a media barrier.
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

    // A hard link is an atomic no-replace publish: exactly one concurrent upload can
    // create the content address, and no existing file can be overwritten.
    if lerr := os.link(up.temp_path, up.final_path); lerr == .Exist {
        return .Already_Present
    } else if lerr != nil {
        up.err = lerr
        return .Failed
    }

    return .Stored
}

// Loop thread. Answers the request if the connection is still there and frees the upload
// either way. Mismatch/already-present/stored map to 400/200/201, no bodies.
blob_published :: proc(up: ^Blob_Upload) {
    outcome, decided := up.outcome.?
    assert(decided, "publish completed without an outcome")
    assert(up.file == nil, "publish left the temp file open")
    defer blob_upload_free(up)

    switch outcome {
    case .Stored:
        log.debugf("daemon: stored blob %s", string(up.claimed[:]))

    case .Failed:
        log.errorf("daemon: blob publish failed: %v", up.err)

    case .Discarded, .Already_Present, .Mismatch:
    }

    c := http_server.conn_resolve(&up.daemon.front_door, up.ticket)
    if c == nil {
        return
    }

    switch outcome {
    case .Stored:
        http_server.respond_text(c, .Created, "")

    case .Already_Present:
        http_server.respond_text(c, .Ok, "")

    case .Mismatch:
        http_server.respond_text(c, .Bad_Request, "hash mismatch")

    case .Failed:
        http_server.respond_text(c, .Internal_Server_Error, "cannot store blob")

    case .Discarded:
        assert(false, "an upload with no answer owed resolved a connection")
    }
}

// Build and store `up`'s owned final and temp paths for `hash` under `blob_dir`. On
// failure, whatever was already set is left for `blob_upload_free` to release.
blob_paths_build :: proc(up: ^Blob_Upload, blob_dir: string, hash: string) -> mem.Allocator_Error {
    assert(len(blob_dir) > 0 && len(hash) == 64, "blob paths need a directory and a 64-hex name")
    assert(up != nil && up.final_path == "" && up.temp_path == "", "blob paths are built once, before anything is set")

    nonce_raw: [8]byte
    crypto.rand_bytes(nonce_raw[:])
    nonce := hex.encode(nonce_raw[:], up.allocator) or_return
    defer delete(nonce, up.allocator)

    up.final_path = strings.concatenate({blob_dir, "/", hash}, up.allocator) or_return
    up.temp_path = strings.concatenate(
        {blob_dir, "/", BLOB_TEMP_PREFIX, hash, ".", string(nonce)},
        up.allocator,
    ) or_return

    return nil
}

// `make_directory_all` leaves an existing directory's mode alone, so a store predating
// `BLOB_DIR_PERMISSIONS` stays exposed. Reported, not tightened: that's the operator's call.
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

// Deletes upload temps (`.upload.<hash>.<nonce>`) under `blob_dir` older than `cutoff`.
// Temp residue only accrues on a crash, so a boot-only pass covers it. Best-effort.
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

    free(up, up.allocator)
}
