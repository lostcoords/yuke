package wire
import "libs:json"

import "core:strings"

// One hunk of a unified diff.
Diff_Hunk :: struct {
    // 1-based start line in old file.
    old_start: u64,

    // Line count in old file.
    old_lines: u64,

    // 1-based start line in new file.
    new_start: u64,

    // Line count in new file.
    new_lines: u64,

    // @bounded LIMITS.max_view_items
    // Hunk body, one line per element (no trailing newlines).
    // Owner: caller/arena.
    lines:     []string,
}

// Decode a diff hunk straight from the token stream.
diff_hunk_from_reader :: proc(d: ^json.Decoder) -> (hunk: Diff_Hunk, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Os,
        Ol,
        Ns,
        Nl,
        Lines,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "old_start":
            hunk.old_start = json.dec_u64(d, MAX_WIRE_INTEGER) or_return
            seen += {.Os}

        case "old_lines":
            hunk.old_lines = json.dec_u64(d, MAX_WIRE_INTEGER) or_return
            seen += {.Ol}

        case "new_start":
            hunk.new_start = json.dec_u64(d, MAX_WIRE_INTEGER) or_return
            seen += {.Ns}

        case "new_lines":
            hunk.new_lines = json.dec_u64(d, MAX_WIRE_INTEGER) or_return
            seen += {.Nl}

        case "lines":
            hunk.lines = json.dec_array(d, json.dec_string) or_return
            seen += {.Lines}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Os, .Ol, .Ns, .Nl, .Lines} {
        return {}, .Mismatched_Payload
    }

    return hunk, .None
}

// Write a diff hunk as a JSON object.
diff_hunk_emit :: proc(e: ^json.Emitter, self: Diff_Hunk) {
    json.object_begin(e)
    json.field_u64(e, "old_start", self.old_start)
    json.field_u64(e, "old_lines", self.old_lines)
    json.field_u64(e, "new_start", self.new_start)
    json.field_u64(e, "new_lines", self.new_lines)
    json.key(e, "lines")
    json.array_begin(e)
    for line in self.lines {
        json.elem(e)
        json.val_string(e, line)
    }

    json.array_end(e)
    json.object_end(e)
}

// Deep-copy into `allocator`.
diff_hunk_clone :: proc(self: Diff_Hunk, allocator := context.allocator) -> Diff_Hunk {
    lines := make([]string, len(self.lines), allocator)
    for i in 0 ..< len(lines) {
        lines[i] = strings.clone(self.lines[i], allocator)
    }

    return Diff_Hunk {
        old_start = self.old_start,
        old_lines = self.old_lines,
        new_start = self.new_start,
        new_lines = self.new_lines,
        lines = lines,
    }
}

// One file in a diff view.
Diff_File :: struct {
    // @bounded 4096
    // New (or current) file path.
    path:     string,

    // @bounded 4096
    // Path in the old tree when the file was renamed.
    old_path: Maybe(string),

    // @bounded LIMITS.max_view_items
    // Per-file hunks in file order. Owner: caller/arena.
    hunks:    []Diff_Hunk,
}

// Decode a diff file straight from the token stream.
diff_file_from_reader :: proc(d: ^json.Decoder) -> (file: Diff_File, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Path,
        Hunks,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "path":
            file.path = json.dec_string(d) or_return
            seen += {.Path}

        case "old_path":
            file.old_path = json.dec_string(d) or_return

        case "hunks":
            file.hunks = json.dec_array(d, diff_hunk_from_reader) or_return
            seen += {.Hunks}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Path, .Hunks} {
        return {}, .Mismatched_Payload
    }

    return file, .None
}

// Write a diff file as a JSON object.
diff_file_emit :: proc(e: ^json.Emitter, self: Diff_File) {
    json.object_begin(e)
    json.field_string(e, "path", self.path)
    json.field_string_opt(e, "old_path", self.old_path)
    json.key(e, "hunks")
    json.array_begin(e)
    for hunk in self.hunks {
        json.elem(e)
        diff_hunk_emit(e, hunk)
    }

    json.array_end(e)
    json.object_end(e)
}

// Deep-copy into `allocator`.
diff_file_clone :: proc(self: Diff_File, allocator := context.allocator) -> Diff_File {
    old_path: Maybe(string)

    if p, ok := self.old_path.?; ok {
        old_path = strings.clone(p, allocator)
    }

    hunks := make([]Diff_Hunk, len(self.hunks), allocator)
    for i in 0 ..< len(hunks) {
        hunks[i] = diff_hunk_clone(self.hunks[i], allocator)
    }

    return {path = strings.clone(self.path, allocator), old_path = old_path, hunks = hunks}
}

// Plain text view.
View_Text :: struct {
    // @unbounded
    // UTF-8 body.
    text:     string,

    // @bounded 64
    // Optional language hint.
    language: Maybe(string),
}

// Markdown view.
View_Markdown :: struct {
    // @unbounded
    // Markdown source.
    text: string,
}

// JSON view.
View_Json :: struct {
    // @unbounded
    // JSON source.
    text: string,
}

// Unified diff view.
View_Diff :: struct {
    // @bounded LIMITS.max_view_items
    // Files in the diff. Owner: caller/arena.
    files: []Diff_File,
}

// Image view.
View_Image :: struct {
    // Image bytes.
    source: Media_Source,

    // @bounded 512
    // Alternative text.
    alt:    Maybe(string),
}

// Display-only rendering hint. Frontends may render natively or ignore. Non-owning.
View :: union {
    View_Text,
    View_Markdown,
    View_Json,
    View_Diff,
    View_Image,
}

// Decode internally-tagged JSON straight from the token stream (any member order).
view_from_reader :: proc(d: ^json.Decoder) -> (view: View, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return
    tag := json.dec_find_tag(d, "type") or_return

    switch tag {
    case "text":
        text: string
        language: Maybe(string)

        Field :: enum {
            Text,
        }

        seen: bit_set[Field]
        for {
            k, kdone := json.dec_key(d) or_return
            if kdone do break

            switch k {
            case "text":
                text = json.dec_string(d) or_return
                seen += {.Text}

            case "language":
                language = json.dec_string(d) or_return

            case "files", "source", "alt":
                return nil, .Mismatched_Payload

            case:
                json.dec_skip(d) or_return
            }
        }

        if .Text not_in seen {
            return nil, .Mismatched_Payload
        }

        return View_Text{text = text, language = language}, .None

    case "markdown", "json":
        text: string

        Field :: enum {
            Text,
        }

        seen: bit_set[Field]
        for {
            k, kdone := json.dec_key(d) or_return
            if kdone do break

            switch k {
            case "text":
                text = json.dec_string(d) or_return
                seen += {.Text}

            case "language", "files", "source", "alt":
                return nil, .Mismatched_Payload

            case:
                json.dec_skip(d) or_return
            }
        }

        if .Text not_in seen {
            return nil, .Mismatched_Payload
        }

        if tag == "markdown" {
            return View_Markdown{text = text}, .None
        }

        return View_Json{text = text}, .None

    case "diff":
        files: []Diff_File

        Field :: enum {
            Files,
        }

        seen: bit_set[Field]
        for {
            k, kdone := json.dec_key(d) or_return
            if kdone do break

            switch k {
            case "files":
                files = json.dec_array(d, diff_file_from_reader) or_return
                seen += {.Files}

            case "text", "language", "source", "alt":
                return nil, .Mismatched_Payload

            case:
                json.dec_skip(d) or_return
            }
        }

        if .Files not_in seen {
            return nil, .Mismatched_Payload
        }

        return View_Diff{files = files}, .None

    case "image":
        source: Media_Source
        alt: Maybe(string)

        Field :: enum {
            Source,
        }

        seen: bit_set[Field]
        for {
            k, kdone := json.dec_key(d) or_return
            if kdone do break

            switch k {
            case "source":
                source = media_source_from_reader(d) or_return
                seen += {.Source}

            case "alt":
                alt = json.dec_string(d) or_return

            case "text", "language", "files":
                return nil, .Mismatched_Payload

            case:
                json.dec_skip(d) or_return
            }
        }

        if .Source not_in seen {
            return nil, .Mismatched_Payload
        }

        return View_Image{source = source, alt = alt}, .None
    }

    return nil, .Mismatched_Payload
}

// Write internally-tagged JSON with `type` first.
view_emit :: proc(e: ^json.Emitter, self: View) {
    json.object_begin(e)

    switch v in self {
    case View_Text:
        json.field_string(e, "type", "text")
        json.field_string(e, "text", v.text)
        json.field_string_opt(e, "language", v.language)

    case View_Markdown:
        json.field_string(e, "type", "markdown")
        json.field_string(e, "text", v.text)

    case View_Json:
        json.field_string(e, "type", "json")
        json.field_string(e, "text", v.text)

    case View_Diff:
        json.field_string(e, "type", "diff")
        json.key(e, "files")
        json.array_begin(e)
        for file in v.files {
            json.elem(e)
            diff_file_emit(e, file)
        }

        json.array_end(e)

    case View_Image:
        json.field_string(e, "type", "image")
        json.key(e, "source")
        media_source_emit(e, v.source)
        json.field_string_opt(e, "alt", v.alt)
    }

    json.object_end(e)
}

// Verify nested collection counts and the aggregate display payload bound.
view_validate :: proc(self: View) -> Validation_Error {
    switch v in self {
    case View_Text:
        if language, ok := v.language.?; ok {
            enforce_bounded(64, language) or_return
        }

    case View_Markdown:
    case View_Json:
    case View_Diff:
        if len(v.files) > LIMITS.max_view_items {
            return .Overflow
        }

        for file in v.files {
            enforce_bounded(4096, file.path) or_return

            if path, ok := file.old_path.?; ok {
                enforce_bounded(4096, path) or_return
            }

            if len(file.hunks) > LIMITS.max_view_items {
                return .Overflow
            }

            for hunk in file.hunks {
                if len(hunk.lines) > LIMITS.max_view_items {
                    return .Overflow
                }
            }
        }

    case View_Image:
        media_source_validate(v.source) or_return

        if alt, ok := v.alt.?; ok {
            enforce_bounded(512, alt) or_return
        }
    }

    if _view_string_bytes(self) > LIMITS.max_view_bytes {
        return .Overflow
    }

    return .None
}

// Deep-copy into `allocator`.
view_clone :: proc(self: View, allocator := context.allocator) -> View {
    switch v in self {
    case View_Text:
        language: Maybe(string)

        if l, ok := v.language.?; ok {
            language = strings.clone(l, allocator)
        }

        return View_Text{text = strings.clone(v.text, allocator), language = language}

    case View_Markdown:
        return View_Markdown{text = strings.clone(v.text, allocator)}

    case View_Json:
        return View_Json{text = strings.clone(v.text, allocator)}

    case View_Diff:
        files := make([]Diff_File, len(v.files), allocator)
        for i in 0 ..< len(files) {
            files[i] = diff_file_clone(v.files[i], allocator)
        }

        return View_Diff{files = files}

    case View_Image:
        alt: Maybe(string)

        if a, ok := v.alt.?; ok {
            alt = strings.clone(a, allocator)
        }

        return View_Image{source = media_source_clone(v.source, allocator), alt = alt}
    }

    return nil
}

// Deep-copy a view slice into `allocator`.
view_clone_slice :: proc(views: []View, allocator := context.allocator) -> []View {
    // Iterate the destination length: a failed `make` yields a zero-length slice, so this
    // under-copies gracefully instead of indexing out of bounds under allocation failure.
    result := make([]View, len(views), allocator)
    for i in 0 ..< len(result) {
        result[i] = view_clone(views[i], allocator)
    }

    return result
}

// Validate one bounded list of display-only views.
view_validate_slice :: proc(views: []View) -> Validation_Error {
    if len(views) > LIMITS.max_views_per_tool {
        return .Overflow
    }

    for v in views {
        view_validate(v) or_return
    }

    return .None
}

// Count raw bytes in every string reachable from a view.
@(private)
_view_string_bytes :: proc(self: View) -> int {
    total := 0

    switch v in self {
    case View_Text:
        total += len(v.text)

        if l, ok := v.language.?; ok {
            total += len(l)
        }

    case View_Markdown:
        total += len(v.text)

    case View_Json:
        total += len(v.text)

    case View_Diff:
        for file in v.files {
            total += len(file.path)

            if p, ok := file.old_path.?; ok {
                total += len(p)
            }

            for hunk in file.hunks {
                for line in hunk.lines {
                    total += len(line)
                }
            }
        }

    case View_Image:
        total += _media_source_string_bytes(v.source)

        if a, ok := v.alt.?; ok {
            total += len(a)
        }
    }

    return total
}

// Count raw bytes in every string reachable from a media source. Fixed-width
// byte ids (the blob hash) and numeric fields carry no string bytes.
@(private)
_media_source_string_bytes :: proc(self: Media_Source) -> int {
    switch v in self {
    case Media_Url:
        return len(v.url)

    case Media_Base64:
        return len(v.mime) + len(v.data)

    case Media_Blob:
        return len(v.mime)
    }

    return 0
}
