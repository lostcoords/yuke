package ui

import "base:intrinsics"

// A cell position on the terminal grid.
Position :: struct {
    x, y: u16,
}

// A rectangular region of the grid, in cells. Edges are half-open: the top-left
// corner is inside, the right/bottom edges are not.
Rect :: struct {
    x, y, width, height: u16,
}

// Right edge (exclusive). Saturating on overflow.
rect_right :: proc(r: Rect) -> u16 {
    return intrinsics.saturating_add(r.x, r.width)
}

// Bottom edge (exclusive). Saturating on overflow.
rect_bottom :: proc(r: Rect) -> u16 {
    return intrinsics.saturating_add(r.y, r.height)
}

// True if `pos` lies inside the rectangle (half-open: right and bottom edges exclusive).
rect_contains :: proc(r: Rect, pos: Position) -> bool {
    return pos.x >= r.x && pos.x < rect_right(r) && pos.y >= r.y && pos.y < rect_bottom(r)
}
