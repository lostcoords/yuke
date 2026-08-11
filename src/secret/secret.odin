package secret

import "core:crypto"
import "core:mem/virtual"

// Wipe and free an owned secret string, then clear the field.
string_destroy :: proc(value: ^string, allocator := context.allocator) {
    assert(value != nil, "secret cleanup needs a string")

    if len(value^) > 0 {
        crypto.zero_explicit(raw_data(transmute([]byte)value^), len(value^))
    }

    delete(value^, allocator)
    value^ = ""
}

// Wipe and free an owned secret byte slice, then clear the field.
bytes_destroy :: proc(value: ^[]byte, allocator := context.allocator) {
    assert(value != nil, "secret cleanup needs a byte slice")

    if len(value^) > 0 {
        crypto.zero_explicit(raw_data(value^), len(value^))
    }

    delete(value^, allocator)
    value^ = nil
}

// Explicitly wipe every allocation made since `temp`, including growing blocks
// which the standard arena reset would otherwise release without clearing.
arena_temp_destroy :: proc(temp: virtual.Arena_Temp) {
    assert(temp.arena != nil, "secret arena cleanup needs an arena")
    assert(temp.block != nil, "secret arena cleanup needs an initialized arena")

    found := false
    for block := temp.arena.curr_block; block != nil; block = block.prev {
        assert(block.used <= block.committed, "secret arena block exceeds committed memory")

        start: uint
        if block == temp.block {
            assert(block.used >= temp.used, "secret arena cleanup is out of order")
            start = temp.used
            found = true
        }

        if block.used > start {
            bytes := block.base[start:][:block.used - start]
            crypto.zero_explicit(raw_data(bytes), len(bytes))
        }
        if found {
            break
        }
    }
    assert(found, "secret arena temp block is not owned by its arena")

    virtual.arena_temp_end(temp)
}
