package secret

import "core:crypto"

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
