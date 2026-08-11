package secret

import "core:mem/virtual"
import "core:testing"

@(test)
test_secret_arena_temp_destroy_wipes_used_memory :: proc(t: ^testing.T) {
    arena: virtual.Arena
    testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
    defer virtual.arena_destroy(&arena)

    temp := virtual.arena_temp_begin(&arena)
    allocation := make([]byte, 32, virtual.arena_allocator(&arena))
    for &byte in allocation {
        byte = 0xa5
    }

    arena_temp_destroy(temp)
    for byte in allocation {
        testing.expect_value(t, byte, u8(0))
    }
}
