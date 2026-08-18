package websocket

import "base:runtime"

// Bounds one vectored send while still allowing one oversized frame by itself.
SEND_BATCH_BYTES :: 256 * 1024
SEND_BATCH_FRAMES :: 512

// Space reserved beyond the application queue limit for one maximum control frame.
SEND_CONTROL_RESERVE_BYTES :: MAX_HEADER_BYTES + 125

// Move whole frames from `queue` into the empty `batch`, preserving order.
coalesce_send_batch :: proc(queue: ^[dynamic][]byte, batch: ^[dynamic][]byte) -> runtime.Allocator_Error {
    assert(queue != nil && batch != nil, "send batch needs queue storage")
    assert(len(queue^) > 0, "cannot coalesce an empty send queue")
    assert(len(batch^) == 0, "previous send batch is still owned")

    total := 0
    count := 0
    for count < len(queue^) {
        frame_bytes := len(queue^[count])
        assert(frame_bytes >= 2, "send queue contains a truncated frame")

        if count > 0 && (total + frame_bytes > SEND_BATCH_BYTES || count >= SEND_BATCH_FRAMES) do break

        total += frame_bytes
        count += 1
    }

    if _, aerr := append(batch, ..queue^[:count]); aerr != nil do return aerr
    remove_range(queue, 0, count)

    assert(count > 0 && len(batch^) == count, "send batch count mismatch")
    assert(count == 1 || total <= SEND_BATCH_BYTES, "multi-frame send batch exceeds byte cap")
    assert(count <= SEND_BATCH_FRAMES, "send batch exceeds frame cap")

    return nil
}

send_queue_bytes :: proc(queue, batch: [][]byte) -> int {
    total := 0
    for frame in queue {
        assert(len(frame) >= 2, "send queue contains a truncated frame")
        assert(len(frame) <= max(int) - total, "send queue byte count overflow")
        total += len(frame)
    }
    for frame in batch {
        assert(len(frame) >= 2, "send batch contains a truncated frame")
        assert(len(frame) <= max(int) - total, "send batch byte count overflow")
        total += len(frame)
    }

    return total
}
