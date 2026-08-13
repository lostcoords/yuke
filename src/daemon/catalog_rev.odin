package daemon

import "core:crypto/sha2"
import "core:encoding/endian"

import store "src:daemon/store"
import wire "src:wire"

@(private, rodata)
REV_HEX_DIGITS := "0123456789abcdef"

// Flatten the effective catalog's visible models into one list ordered by public
// model id. Each `Model_Info` borrows the effective catalog's owned strings, so the
// view must not outlive `effective`; only the returned slice is owned by `allocator`.
// The order matches the resolver's (providers by id, models by public id), so the
// same list feeds both `catalog_rev` and the `catalog.list` response.
catalog_models_view :: proc(
    effective: store.Effective_Catalog,
    allocator := context.allocator,
) -> (
    models: []wire.Model_Info,
    ok: bool,
) {
    total := 0
    for provider in effective.providers {
        total += len(provider.models)
    }

    if total == 0 {
        return nil, true
    }

    view, err := make([]wire.Model_Info, total, allocator)
    if err != nil {
        return nil, false
    }

    index := 0
    for provider in effective.providers {
        for model in provider.models {
            view[index] = model.info
            index += 1
        }
    }

    assert(index == total, "the view holds every visible model")

    return view, true
}

// Compute the catalog revision over the exact `catalog.list` content a client caches:
// the visible model list plus the health block. Any change to a client-visible field
// changes the digest, so `since_rev == current` soundly means the cached result is
// still accurate. It does not cover private inference metadata. The caller must supply
// `models` and `health.skipped` in a deterministic order (the resolver's), matching
// the order the `catalog.list` response emits.
//
// The value is a SHA-256 hex digest, the 64 lowercase-hex bytes `Catalog_Rev` requires.
// Clients treat it as opaque, so the length-prefixed preimage need not match any wire
// encoding — only determinism and sensitivity matter.
catalog_rev :: proc(models: []wire.Model_Info, health: wire.Catalog_Health) -> wire.Catalog_Rev {
    assert(len(models) <= int(wire.LIMITS.max_catalog_models), "the rev covers a bounded catalog")

    ctx: sha2.Context_256
    sha2.init_256(&ctx)

    rev_bytes(&ctx, transmute([]byte)string("yuke.catalog.rev.v1"))

    rev_u64(&ctx, u64(len(models)))
    for model in models {
        rev_str(&ctx, string(model.id))
        rev_str(&ctx, model.provider)
        rev_str(&ctx, model.name)
        rev_u64(&ctx, model.context_window)
        rev_u64(&ctx, model.max_output_tokens)
        rev_u64(&ctx, u64(len(model.reasoning_levels)))
        for level in model.reasoning_levels {
            rev_str(&ctx, level)
        }
        rev_str(&ctx, model.default_reasoning)
        rev_u8(&ctx, 1 if model.supports_vision else 0)
        rev_u8(&ctx, 1 if model.supports_tools else 0)
        rev_f64(&ctx, model.cost.input)
        rev_f64(&ctx, model.cost.output)
        rev_f64(&ctx, model.cost.cache_read)
        rev_f64(&ctx, model.cost.cache_write)
    }

    rev_u64(&ctx, u64(len(health.skipped)))
    for skipped in health.skipped {
        rev_str(&ctx, skipped.provider)
        rev_u8(&ctx, rev_skip_reason_tag(skipped.reason))
    }
    if message, present := health.load_error.?; present {
        rev_u8(&ctx, 1)
        rev_str(&ctx, message)
    } else {
        rev_u8(&ctx, 0)
    }

    digest: [sha2.DIGEST_SIZE_256]byte
    sha2.final(&ctx, digest[:])

    out: [64]u8
    for value, index in digest {
        out[index * 2] = REV_HEX_DIGITS[value >> 4]
        out[index * 2 + 1] = REV_HEX_DIGITS[value & 0xf]
    }

    return wire.Catalog_Rev(out)
}

@(private)
rev_skip_reason_tag :: proc(reason: wire.Skip_Reason) -> u8 {
    switch _ in reason {
    case wire.Skip_Reason_Missing_Credential:
        return 1

    case wire.Skip_Reason_Invalid_Config:
        return 2
    }

    return 0
}

@(private)
rev_bytes :: proc(ctx: ^sha2.Context_256, data: []byte) {
    sha2.update(ctx, data)
}

@(private)
rev_str :: proc(ctx: ^sha2.Context_256, value: string) {
    rev_u64(ctx, u64(len(value)))
    if len(value) > 0 {
        sha2.update(ctx, transmute([]byte)value)
    }
}

@(private)
rev_u64 :: proc(ctx: ^sha2.Context_256, value: u64) {
    buf: [8]u8
    endian.put_u64(buf[:], .Little, value)
    sha2.update(ctx, buf[:])
}

@(private)
rev_f64 :: proc(ctx: ^sha2.Context_256, value: f64) {
    buf: [8]u8
    endian.put_f64(buf[:], .Little, value)
    sha2.update(ctx, buf[:])
}

@(private)
rev_u8 :: proc(ctx: ^sha2.Context_256, value: u8) {
    buf := [1]u8{value}
    sha2.update(ctx, buf[:])
}
