# Clipped text source mapping

A `TextView` maps rendered segments to offsets in a section's source text.
The `elision` mapping keeps each visible prefix unit at its source offset.
The final displayed UTF-16 unit represents the rest of the source range.
Use a nonempty segment whose final unit is an ellipsis or another clipping marker.

For source `abcdef`, the segment `ab…` maps `a` to offset 0 and `b` to offset 1.
The ellipsis starts at offset 2 and ends at offset 6.
A position inside the hidden suffix maps before or after the ellipsis according to its bias.
Copying the source range still returns `abcdef`.

Tool headings use this mapping for a clipped subject.
Visible caret positions stay at their source offsets when a call folds or the pane resizes.
