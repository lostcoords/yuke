package ui

import "core:testing"

@(test)
test_style_patch_overlays_and_unions :: proc(t: ^testing.T) {
    base := Style {
        fg   = Ansi_Color.Red,
        bg   = Ansi_Color.Black,
        mods = {.Bold},
    }
    top := Style {
        fg   = Ansi_Color.Green,
        mods = {.Italic},
    }
    out := style_patch(base, top)

    // Top fg wins
    testing.expect(t, out.fg != nil)
    testing.expect(t, out.fg.(Ansi_Color) == Ansi_Color.Green)

    // Base bg kept (top.bg nil)
    testing.expect(t, out.bg != nil)
    testing.expect(t, out.bg.(Ansi_Color) == Ansi_Color.Black)

    // Modifiers are unioned
    testing.expect(t, .Bold in out.mods)
    testing.expect(t, .Italic in out.mods)
}

@(test)
test_style_zero_value_is_inherit :: proc(t: ^testing.T) {
    s := Style{}

    // All fields should be nil/unset
    testing.expect(t, s.fg == nil)
    testing.expect(t, s.bg == nil)
    testing.expect(t, s.mods == {})
}

@(test)
test_style_patch_with_nil_fg_bg :: proc(t: ^testing.T) {
    base := Style {
        fg = Ansi_Color.Red,
        bg = Ansi_Color.Blue,
    }
    top := Style {
        fg = Ansi_Color.Green,
        // bg is nil, should inherit from base
    }
    out := style_patch(base, top)

    // fg from top
    testing.expect(t, out.fg != nil)
    testing.expect(t, out.fg.(Ansi_Color) == Ansi_Color.Green)

    // bg from base (top.bg is nil)
    testing.expect(t, out.bg != nil)
    testing.expect(t, out.bg.(Ansi_Color) == Ansi_Color.Blue)
}

@(test)
test_style_indexed_and_rgb_colors :: proc(t: ^testing.T) {
    // Test Indexed color
    base := Style {
        fg = Indexed(237),
    }
    testing.expect(t, base.fg != nil)
    testing.expect(t, base.fg.(Indexed) == Indexed(237))

    // Test RGB color
    rgb_style := Style {
        bg = Rgb{r = 255, g = 128, b = 64},
    }
    testing.expect(t, rgb_style.bg != nil)
    rgb := rgb_style.bg.(Rgb)
    testing.expect_value(t, rgb.r, u8(255))
    testing.expect_value(t, rgb.g, u8(128))
    testing.expect_value(t, rgb.b, u8(64))
}

@(test)
test_style_modifiers_never_cleared :: proc(t: ^testing.T) {
    base := Style {
        mods = {.Bold, .Underlined},
    }
    top := Style {
        mods = {.Italic},
    }
    out := style_patch(base, top)

    // All three modifiers should be present; patch never removes
    testing.expect(t, .Bold in out.mods)
    testing.expect(t, .Underlined in out.mods)
    testing.expect(t, .Italic in out.mods)
}
