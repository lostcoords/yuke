package ui

import "core:testing"

@(test)
test_rect_edges_and_contains :: proc(t: ^testing.T) {
    r := Rect {
        x      = 2,
        y      = 3,
        width  = 4,
        height = 5,
    }
    testing.expect_value(t, rect_right(r), u16(6))
    testing.expect_value(t, rect_bottom(r), u16(8))
    testing.expect(t, rect_contains(r, {x = 2, y = 3})) // top-left corner
    testing.expect(t, rect_contains(r, {x = 5, y = 7})) // bottom-right inside
    testing.expect(t, !rect_contains(r, {x = 6, y = 3})) // right edge is exclusive
    testing.expect(t, !rect_contains(r, {x = 1, y = 3})) // left of x
    testing.expect(t, !rect_contains(r, {x = 2, y = 8})) // bottom edge is exclusive
}

@(test)
test_rect_saturating :: proc(t: ^testing.T) {
    r := Rect {
        x      = 65535,
        y      = 65535,
        width  = 1,
        height = 1,
    }
    testing.expect_value(t, rect_right(r), u16(65535)) // saturates at max u16
    testing.expect_value(t, rect_bottom(r), u16(65535)) // saturates at max u16
}
