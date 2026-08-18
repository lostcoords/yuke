package ui

// ANSI terminal colors. Reset selects the terminal default; unqualified names are dark colors,
// light_* variants are bright; indexed is a 256-palette entry; rgb is 24-bit truecolor.
Ansi_Color :: enum u8 {
    Reset,
    Black,
    Red,
    Green,
    Yellow,
    Blue,
    Magenta,
    Cyan,
    Gray,
    Dark_Gray,
    Light_Red,
    Light_Green,
    Light_Yellow,
    Light_Blue,
    Light_Magenta,
    Light_Cyan,
    White,
}

// 24-bit RGB color.
Rgb :: struct {
    r, g, b: u8,
}

// A 256-color palette index.
Indexed :: distinct u8

// A terminal color. nil means inherit/unset from the cell underneath; Reset means
// explicitly select the terminal default; indexed is a 256-palette entry; rgb is 24-bit truecolor.
Color :: union {
    Ansi_Color,
    Indexed,
    Rgb,
}

// Terminal text modifiers, packed as bit flags.
Modifier :: enum u8 {
    Bold,
    Dim,
    Italic,
    Underlined,
    Reversed,
    Crossed_Out,
}

Modifiers :: bit_set[Modifier;u8]

// A style patch: nil colors inherit the cell underneath, while Ansi_Color.Reset
// explicitly selects the terminal default. Modifiers are added (unioned) to existing ones;
// style_patch never removes modifiers from the base.
Style :: struct {
    fg, bg: Color,
    mods:   Modifiers,
}

// Overlay top onto base: top's set colors (non-nil) win; base colors are kept for nil in top.
// Modifiers are set-unioned (bitwise OR). This is the ONLY merge semantic and preserves base modifiers.
style_patch :: proc(base, top: Style) -> Style {
    fg := base.fg
    if top.fg != nil do fg = top.fg

    bg := base.bg
    if top.bg != nil do bg = top.bg

    mods := base.mods | top.mods

    return {fg = fg, bg = bg, mods = mods}
}
