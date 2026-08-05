package provider

import "src:wire"

// Per-turn streaming decoder, one arm per provider protocol. The turn owns the
// union and routes every decode and finish through it.
Provider_Decoder :: union {
    Anthropic_Decoder,
    Openai_Chat_Decoder,
    Openai_Responses_Decoder,
}

#assert(len(wire.Provider_Protocol) == 3)

// True only for protocols whose decoder and request builder are both
// implemented. The OpenAI slices flip their entries on as they land.
protocol_supported :: proc(p: wire.Provider_Protocol) -> bool {
    switch p {
    case .Anthropic_Messages, .Openai_Chat, .Openai_Responses:
        return true
    }

    return false
}

// Construct the decoder arm for `protocol`. Callers gate on `protocol_supported`
// before starting a turn; the switch stays exhaustive so an unsupported arm is a
// deliberate stub, never a silent nil.
decoder_init :: proc(protocol: wire.Provider_Protocol, allocator := context.allocator) -> Provider_Decoder {
    assert(allocator.procedure != nil, "provider decoder needs a valid turn allocator")

    switch protocol {
    case .Anthropic_Messages:
        return anthropic_decoder_init(allocator)

    case .Openai_Chat:
        return openai_chat_decoder_init(allocator)

    case .Openai_Responses:
        return openai_responses_decoder_init(allocator)
    }

    unreachable()
}

// Decode one SSE `data` payload, appending its neutral events to `events`.
decoder_decode :: proc(
    d: ^Provider_Decoder,
    data: string,
    events: ^[dynamic]Stream_Event,
    scratch_allocator := context.allocator,
) -> Transport_Error {
    assert(d != nil, "provider decode needs a decoder")
    assert(events != nil, "provider decode needs an event queue")

    switch &dec in d {
    case Anthropic_Decoder:
        return anthropic_decoder_decode(&dec, data, events, scratch_allocator)

    case Openai_Chat_Decoder:
        return openai_chat_decoder_decode(&dec, data, events, scratch_allocator)

    case Openai_Responses_Decoder:
        return openai_responses_decoder_decode(&dec, data, events, scratch_allocator)
    }

    unreachable()
}

// Finish at transport EOF, appending zero or more late neutral events to
// `events`. `scratch_allocator` holds only per-call JSON trees a decoder frees
// itself; the turn schedules any appended events.
decoder_finish :: proc(
    d: ^Provider_Decoder,
    events: ^[dynamic]Stream_Event,
    scratch_allocator := context.allocator,
) -> Transport_Error {
    assert(d != nil, "provider finish needs a decoder")
    assert(events != nil, "provider finish needs an event queue")

    switch &dec in d {
    case Anthropic_Decoder:
        return anthropic_decoder_finish(&dec, events, scratch_allocator)

    case Openai_Chat_Decoder:
        return openai_chat_decoder_finish(&dec, events, scratch_allocator)

    case Openai_Responses_Decoder:
        return openai_responses_decoder_finish(&dec, events, scratch_allocator)
    }

    unreachable()
}
