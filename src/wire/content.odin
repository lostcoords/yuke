package wire
import "libs:json"

import "core:strings"

// Fetched over HTTP by URL.
Media_Url :: struct {
    // @bounded 4096
    // Remote URL.
    url: string,
}

// Inlined as base64 bytes.
Media_Base64 :: struct {
    // @bounded 256
    // MIME type.
    mime: string,

    // @bounded LIMITS.max_inline_media_base64_bytes
    // Base64-encoded bytes. The decoded length is the tighter rule:
    // <= LIMITS.max_inline_media_bytes.
    data: string,
}

// Referenced by content hash, fetched separately.
Media_Blob :: struct {
    // @fixed 64
    // Content hash, lowercase hex.
    hash:  [64]u8,

    // @bounded 256
    // MIME type.
    mime:  string,

    // Decoded byte length.
    bytes: u64,
}

// Where media bytes live. Inline (base64) capped at LIMITS.max_inline_media_bytes;
// blob is a content hash fetched over HTTP.
Media_Source :: union {
    // Fetched over HTTP by URL.
    Media_Url,

    // Inlined as base64 bytes.
    Media_Base64,

    // Referenced by content hash, fetched separately.
    Media_Blob,
}

// Decode internally-tagged JSON straight from the token stream (any member order).
media_source_from_reader :: proc(d: ^Decoder) -> (src: Media_Source, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "url":
        url: string

        Field :: enum {
            Url,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "url":
                url = dec_string(d) or_return
                seen += {.Url}

            case "mime", "data", "hash", "bytes":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if .Url not_in seen {
            return nil, .Mismatched_Payload
        }

        return Media_Url{url = url}, .None

    case "base64":
        mime, data: string

        Field :: enum {
            Mime,
            Data,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "mime":
                mime = dec_string(d) or_return
                seen += {.Mime}

            case "data":
                data = dec_string(d) or_return
                seen += {.Data}

            case "url", "hash", "bytes":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Mime, .Data} {
            return nil, .Mismatched_Payload
        }

        return Media_Base64{mime = mime, data = data}, .None

    case "blob":
        hash: [64]u8
        mime: string
        bytes: u64

        Field :: enum {
            Hash,
            Mime,
            Bytes,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "hash":
                hash = dec_fixed(d, 64) or_return
                seen += {.Hash}

            case "mime":
                mime = dec_string(d) or_return
                seen += {.Mime}

            case "bytes":
                bytes = dec_u64(d) or_return
                seen += {.Bytes}

            case "url", "data":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Hash, .Mime, .Bytes} {
            return nil, .Mismatched_Payload
        }

        return Media_Blob{hash = hash, mime = mime, bytes = bytes}, .None
    }

    return nil, .Mismatched_Payload
}

// Write internally-tagged JSON with `type` first.
media_source_emit :: proc(e: ^json.Emitter, self: Media_Source) {
    json.object_begin(e)

    switch v in self {
    case Media_Url:
        json.field_string(e, "type", "url")
        json.field_string(e, "url", v.url)

    case Media_Base64:
        json.field_string(e, "type", "base64")
        json.field_string(e, "mime", v.mime)
        json.field_string(e, "data", v.data)

    case Media_Blob:
        json.field_string(e, "type", "blob")
        json.field_id(e, "hash", v.hash)
        json.field_string(e, "mime", v.mime)
        json.field_u64(e, "bytes", v.bytes)
    }

    json.object_end(e)
}

// Verify annotated field bounds.
media_source_validate :: proc(self: Media_Source) -> Validation_Error {
    switch v in self {
    case Media_Url:
        return enforce_bounded(4096, v.url)

    case Media_Base64:
        enforce_bounded(256, v.mime) or_return
        return _validate_base64_inline(v.data)

    case Media_Blob:
        enforce_id(v.hash) or_return
        enforce_bounded(256, v.mime) or_return

        if v.bytes > LIMITS.max_blob_bytes {
            return .Overflow
        }
    }

    return .None
}

// Deep-copy into `allocator`.
media_source_clone :: proc(self: Media_Source, allocator := context.allocator) -> Media_Source {
    switch v in self {
    case Media_Url:
        return Media_Url{url = strings.clone(v.url, allocator)}

    case Media_Base64:
        return Media_Base64{mime = strings.clone(v.mime, allocator), data = strings.clone(v.data, allocator)}

    case Media_Blob:
        return Media_Blob{hash = v.hash, mime = strings.clone(v.mime, allocator), bytes = v.bytes}
    }

    return nil
}

// Reject inline base64 that is malformed or would decode past the inline cap.
@(private)
_validate_base64_inline :: proc(data: string) -> Validation_Error {
    enforce_bounded(LIMITS.max_inline_media_base64_bytes, data) or_return

    if len(data) % 4 != 0 {
        return .Mismatched_Payload
    }

    padding := 0
    n := len(data)

    if n >= 1 && data[n - 1] == '=' {
        padding += 1
    }

    if n >= 2 && data[n - 2] == '=' {
        padding += 1
    }

    decoded_len := (n / 4) * 3 - padding

    if decoded_len > LIMITS.max_inline_media_bytes {
        return .Overflow
    }

    seen_padding := 0
    for i in 0 ..< n {
        b := data[i]

        if b == '=' {
            seen_padding += 1

            if seen_padding > 2 {
                return .Mismatched_Payload
            }
        } else {
            if seen_padding != 0 || !_is_base64_char(b) {
                return .Mismatched_Payload
            }
        }
    }

    return .None
}

@(private)
_is_base64_char :: proc(c: u8) -> bool {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '+' || c == '/'
}

// Plain UTF-8 text.
Content_Text :: struct {
    // @unbounded
    // UTF-8 text.
    text: string,
}

// Image content.
Content_Image :: struct {
    // Image bytes.
    source: Media_Source,

    // @bounded 32
    // Optional detail hint (e.g. `"low"` / `"high"`).
    detail: Maybe(string),
}

// Audio content.
Content_Audio :: struct {
    // Audio bytes.
    source: Media_Source,

    // @bounded 64
    // Audio container format.
    format: string,
}

// Arbitrary file content.
Content_File :: struct {
    // File bytes.
    source:   Media_Source,

    // @bounded 512
    // Original filename.
    filename: Maybe(string),
}

// One piece of user or model content. Non-owning.
Content_Part :: union {
    Content_Text,
    Content_Image,
    Content_Audio,
    Content_File,
}

// Decode internally-tagged JSON straight from the token stream (any member order).
content_part_from_reader :: proc(d: ^Decoder) -> (part: Content_Part, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "text":
        text: string

        Field :: enum {
            Text,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "text":
                text = dec_string(d) or_return
                seen += {.Text}

            case "source", "detail", "format", "filename":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if .Text not_in seen {
            return nil, .Mismatched_Payload
        }

        return Content_Text{text = text}, .None

    case "image":
        source: Media_Source
        detail: Maybe(string)

        Field :: enum {
            Source,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "source":
                source = media_source_from_reader(d) or_return
                seen += {.Source}

            case "detail":
                detail = dec_string(d) or_return

            case "text", "format", "filename":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if .Source not_in seen {
            return nil, .Mismatched_Payload
        }

        return Content_Image{source = source, detail = detail}, .None

    case "audio":
        source: Media_Source
        format: string

        Field :: enum {
            Source,
            Format,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "source":
                source = media_source_from_reader(d) or_return
                seen += {.Source}

            case "format":
                format = dec_string(d) or_return
                seen += {.Format}

            case "text", "detail", "filename":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Source, .Format} {
            return nil, .Mismatched_Payload
        }

        return Content_Audio{source = source, format = format}, .None

    case "file":
        source: Media_Source
        filename: Maybe(string)

        Field :: enum {
            Source,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "source":
                source = media_source_from_reader(d) or_return
                seen += {.Source}

            case "filename":
                filename = dec_string(d) or_return

            case "text", "detail", "format":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if .Source not_in seen {
            return nil, .Mismatched_Payload
        }

        return Content_File{source = source, filename = filename}, .None
    }

    return nil, .Mismatched_Payload
}

// Write internally-tagged JSON with `type` first.
content_part_emit :: proc(e: ^json.Emitter, self: Content_Part) {
    json.object_begin(e)

    switch v in self {
    case Content_Text:
        json.field_string(e, "type", "text")
        json.field_string(e, "text", v.text)

    case Content_Image:
        json.field_string(e, "type", "image")
        json.key(e, "source")
        media_source_emit(e, v.source)
        json.field_string_opt(e, "detail", v.detail)

    case Content_Audio:
        json.field_string(e, "type", "audio")
        json.key(e, "source")
        media_source_emit(e, v.source)
        json.field_string(e, "format", v.format)

    case Content_File:
        json.field_string(e, "type", "file")
        json.key(e, "source")
        media_source_emit(e, v.source)
        json.field_string_opt(e, "filename", v.filename)
    }

    json.object_end(e)
}

// Verify annotated field bounds.
content_part_validate :: proc(self: Content_Part) -> Validation_Error {
    switch v in self {
    case Content_Text:
        return .None

    case Content_Image:
        media_source_validate(v.source) or_return

        if detail, ok := v.detail.?; ok {
            return enforce_bounded(32, detail)
        }

    case Content_Audio:
        media_source_validate(v.source) or_return
        return enforce_bounded(64, v.format)

    case Content_File:
        media_source_validate(v.source) or_return

        if filename, ok := v.filename.?; ok {
            return enforce_bounded(512, filename)
        }
    }

    return .None
}

// Deep-copy into `allocator`.
content_part_clone :: proc(self: Content_Part, allocator := context.allocator) -> Content_Part {
    switch v in self {
    case Content_Text:
        return Content_Text{text = strings.clone(v.text, allocator)}

    case Content_Image:
        detail: Maybe(string)

        if d, ok := v.detail.?; ok {
            detail = strings.clone(d, allocator)
        }

        return Content_Image{source = media_source_clone(v.source, allocator), detail = detail}

    case Content_Audio:
        return Content_Audio {
            source = media_source_clone(v.source, allocator),
            format = strings.clone(v.format, allocator),
        }

    case Content_File:
        filename: Maybe(string)

        if f, ok := v.filename.?; ok {
            filename = strings.clone(f, allocator)
        }

        return Content_File{source = media_source_clone(v.source, allocator), filename = filename}
    }

    return nil
}
