package wire

import "core:strings"

// Display-only tool output views.

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

    // Hunk body, one line per element (no trailing newlines). At most 1024.
    // Owner: caller/arena.
    lines:     []string,
}

// Decode a diff hunk straight from the token stream.
diff_hunk_from_reader :: proc(d: ^Decoder) -> (hunk: Diff_Hunk, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Os,
        Ol,
        Ns,
        Nl,
        Lines,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "old_start":
            hunk.old_start = dec_u64(d) or_return
            seen += {.Os}

        case "old_lines":
            hunk.old_lines = dec_u64(d) or_return
            seen += {.Ol}

        case "new_start":
            hunk.new_start = dec_u64(d) or_return
            seen += {.Ns}

        case "new_lines":
            hunk.new_lines = dec_u64(d) or_return
            seen += {.Nl}

        case "lines":
            hunk.lines = dec_array(d, dec_string) or_return
            seen += {.Lines}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Os, .Ol, .Ns, .Nl, .Lines} {
        return {}, .Mismatched_Payload
    }

    return hunk, .None
}

// Write a diff hunk as a JSON object.
diff_hunk_emit :: proc(e: ^Emitter, self: Diff_Hunk) {
    object_begin(e)
    field_u64(e, "old_start", self.old_start)
    field_u64(e, "old_lines", self.old_lines)
    field_u64(e, "new_start", self.new_start)
    field_u64(e, "new_lines", self.new_lines)
    key(e, "lines")
    array_begin(e)
    for line in self.lines {
        elem(e)
        val_string(e, line)
    }

    array_end(e)
    object_end(e)
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
    // New (or current) file path. @bounded 4096
    path:     string,

    // Path in the old tree when the file was renamed. @bounded 4096
    old_path: Maybe(string),

    // Per-file hunks in file order. At most 1024. Owner: caller/arena.
    hunks:    []Diff_Hunk,
}

// Decode a diff file straight from the token stream.
diff_file_from_reader :: proc(d: ^Decoder) -> (file: Diff_File, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Path,
        Hunks,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "path":
            file.path = dec_string(d) or_return
            seen += {.Path}

        case "old_path":
            if !dec_is_null(d) {
                file.old_path = dec_string(d) or_return
            }

        case "hunks":
            file.hunks = dec_array(d, diff_hunk_from_reader) or_return
            seen += {.Hunks}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Path, .Hunks} {
        return {}, .Mismatched_Payload
    }

    return file, .None
}

// Write a diff file as a JSON object.
diff_file_emit :: proc(e: ^Emitter, self: Diff_File) {
    object_begin(e)
    field_string(e, "path", self.path)
    field_string_opt(e, "old_path", self.old_path)
    key(e, "hunks")
    array_begin(e)
    for hunk in self.hunks {
        elem(e)
        diff_hunk_emit(e, hunk)
    }

    array_end(e)
    object_end(e)
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

    return Diff_File{path = strings.clone(self.path, allocator), old_path = old_path, hunks = hunks}
}

// One field in a form view.
Form_Field :: struct {
    // Field key. @bounded 128
    name:  string,

    // Human-readable label. @bounded 256
    label: string,

    // Pre-filled value, if any.
    value: Maybe(string),
}

// Decode a form field straight from the token stream.
form_field_from_reader :: proc(d: ^Decoder) -> (field: Form_Field, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Name,
        Label,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "name":
            field.name = dec_string(d) or_return
            seen += {.Name}

        case "label":
            field.label = dec_string(d) or_return
            seen += {.Label}

        case "value":
            if !dec_is_null(d) {
                field.value = dec_string(d) or_return
            }

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Name, .Label} {
        return {}, .Mismatched_Payload
    }

    return field, .None
}

// Write a form field as a JSON object.
form_field_emit :: proc(e: ^Emitter, self: Form_Field) {
    object_begin(e)
    field_string(e, "name", self.name)
    field_string(e, "label", self.label)
    field_string_opt(e, "value", self.value)
    object_end(e)
}

// Deep-copy into `allocator`.
form_field_clone :: proc(self: Form_Field, allocator := context.allocator) -> Form_Field {
    value: Maybe(string)

    if val, ok := self.value.?; ok {
        value = strings.clone(val, allocator)
    }

    return Form_Field {
        name = strings.clone(self.name, allocator),
        label = strings.clone(self.label, allocator),
        value = value,
    }
}

// Plain text view.
View_Text :: struct {
    // UTF-8 body.
    text:     string,

    // Optional language hint. @bounded 64
    language: Maybe(string),
}

// Markdown view.
View_Markdown :: struct {
    // Markdown source.
    text: string,
}

// JSON view.
View_Json :: struct {
    // JSON source.
    text: string,
}

// Unified diff view.
View_Diff :: struct {
    // Files in the diff. At most 1024. Owner: caller/arena.
    files: []Diff_File,
}

// Form view.
View_Form :: struct {
    // Form fields. At most 1024. Owner: caller/arena.
    fields: []Form_Field,
}

// Image view.
View_Image :: struct {
    // Image bytes.
    source: Media_Source,

    // Alternative text. @bounded 512
    alt:    Maybe(string),
}

// Display-only rendering hint. Frontends may render natively or ignore. Non-owning.
View :: union {
    View_Text,
    View_Markdown,
    View_Json,
    View_Diff,
    View_Form,
    View_Image,
}

// Decode internally-tagged JSON straight from the token stream (any member order).
view_from_reader :: proc(d: ^Decoder) -> (view: View, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "text":
        text: string
        language: Maybe(string)

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

            case "language":
                if !dec_is_null(d) {
                    language = dec_string(d) or_return
                }

            case "files", "fields", "source", "alt":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
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
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "text":
                text = dec_string(d) or_return
                seen += {.Text}

            case "language", "files", "fields", "source", "alt":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
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
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "files":
                files = dec_array(d, diff_file_from_reader) or_return
                seen += {.Files}

            case "text", "language", "fields", "source", "alt":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if .Files not_in seen {
            return nil, .Mismatched_Payload
        }

        return View_Diff{files = files}, .None

    case "form":
        fields: []Form_Field

        Field :: enum {
            Fields,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "fields":
                fields = dec_array(d, form_field_from_reader) or_return
                seen += {.Fields}

            case "text", "language", "files", "source", "alt":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if .Fields not_in seen {
            return nil, .Mismatched_Payload
        }

        return View_Form{fields = fields}, .None

    case "image":
        source: Media_Source
        alt: Maybe(string)

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

            case "alt":
                if !dec_is_null(d) {
                    alt = dec_string(d) or_return
                }

            case "text", "language", "files", "fields":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
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
view_emit :: proc(e: ^Emitter, self: View) {
    object_begin(e)

    switch v in self {
    case View_Text:
        field_string(e, "type", "text")
        field_string(e, "text", v.text)
        field_string_opt(e, "language", v.language)

    case View_Markdown:
        field_string(e, "type", "markdown")
        field_string(e, "text", v.text)

    case View_Json:
        field_string(e, "type", "json")
        field_string(e, "text", v.text)

    case View_Diff:
        field_string(e, "type", "diff")
        key(e, "files")
        array_begin(e)
        for file in v.files {
            elem(e)
            diff_file_emit(e, file)
        }

        array_end(e)

    case View_Form:
        field_string(e, "type", "form")
        key(e, "fields")
        array_begin(e)
        for ff in v.fields {
            elem(e)
            form_field_emit(e, ff)
        }

        array_end(e)

    case View_Image:
        field_string(e, "type", "image")
        key(e, "source")
        media_source_emit(e, v.source)
        field_string_opt(e, "alt", v.alt)
    }

    object_end(e)
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

    case View_Form:
        if len(v.fields) > LIMITS.max_view_items {
            return .Overflow
        }

        for ff in v.fields {
            enforce_bounded(128, ff.name) or_return
            enforce_bounded(256, ff.label) or_return
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

    case View_Form:
        fields := make([]Form_Field, len(v.fields), allocator)
        for i in 0 ..< len(fields) {
            fields[i] = form_field_clone(v.fields[i], allocator)
        }

        return View_Form{fields = fields}

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

    case View_Form:
        for ff in v.fields {
            total += len(ff.name)
            total += len(ff.label)

            if val, ok := ff.value.?; ok {
                total += len(val)
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
