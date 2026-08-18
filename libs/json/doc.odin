/*
Package json is the codebase's single JSON module. It bundles yuke's own encoders
(write_string escapes as raw UTF-8, invalid bytes becoming U+FFFD; write_u64,
write_f64, write_raw) and typed object readers, and re-exports in std.odin the
core:encoding/json surface the codebase uses, so every caller imports only this one
package. The re-export aliases are compile-time: add one when a caller first needs a
symbol, or swap one for a local implementation to fix or extend it in a single place.

The readers (read_string, read_bool, read_u64, read_f64_nonneg, read_object) report
`(value, present, valid)`: a missing or null member is absent (present=false,
valid=true); a present member of the wrong type or out of bounds is invalid.
*/

package json
