/*
The ui package provides a double-buffered terminal grid and grapheme-correct text
helpers for terminal rendering. Widgets draw into the current cells; `flush_diff`
writes only the cells that changed since the previous frame and advances the
buffer.

This package does not depend on `src/term`: the terminal control bytes it needs are
small named escape-sequence constants in `buffer.odin`, emitted directly to an
`io.Writer`.

The package is layered as:

  - `buffer.odin`: the double-buffered terminal grid. The buffer owns `cells`,
    `prev`, and two Grapheme_Pools, allocated at `buffer_init`/`buffer_resize` and
    freed at `buffer_destroy`. Grapheme clusters written this frame live in `pool`;
    the previous frame's clusters live in `prev_pool` for the diff.
  - `cell.odin`: terminal grid cells and the grapheme pool. A Cell stays small and
    copyable (the grid is an array of them), so its glyph is a compact u32: an
    inline Unicode scalar, or an index into a per-buffer Grapheme_Pool for
    multi-scalar clusters (e-acute, ZWJ emoji, flags).
  - `text.odin`: width-aware text helpers over the unicode layer: grapheme-correct
    truncation, cell-window slicing, and greedy soft-wrap. `clip_cells`/
    `cell_width`/`slice_cells` return borrowed sub-slices of the input; only
    `wrap_text`'s outer row slice allocates. Nothing here owns `text`.
  - `unicode.odin`: Unicode grapheme clustering (UAX #29) and display width.
    Segmentation is built on `core:unicode/utf8`'s Grapheme_Iterator; width
    reproduces zg's DisplayWidth (graphemeWidth/codePointWidth) rather than core's
    own cluster-width notion, since the two disagree on cases like variation
    selectors and skin-tone modifiers. Thin, stateless, zero-allocation wrappers.
  - `geometry.odin`: cell positions, rectangles, and saturating edge helpers.
  - `style.odin`: ANSI terminal colors and text styles.
*/

package ui
