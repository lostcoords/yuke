package json

import stdjson "core:encoding/json"

// Re-export the core:encoding/json surface the codebase uses, so every caller imports
// only `libs:json` and this package is the single JSON source of truth. The aliases are
// compile-time, so they cost nothing at runtime. Add a symbol here the first time a
// caller needs it; swap an alias for our own implementation to fix or extend it in one
// place for every caller.

Value :: stdjson.Value
Object :: stdjson.Object
Array :: stdjson.Array
String :: stdjson.String
Null :: stdjson.Null
Integer :: stdjson.Integer
Float :: stdjson.Float
Boolean :: stdjson.Boolean
Parser :: stdjson.Parser
Token :: stdjson.Token
Error :: stdjson.Error
Specification :: stdjson.Specification
Marshal_Options :: stdjson.Marshal_Options
Marshal_Error :: stdjson.Marshal_Error
Unmarshal_Error :: stdjson.Unmarshal_Error

DEFAULT_SPECIFICATION :: stdjson.DEFAULT_SPECIFICATION

marshal :: stdjson.marshal
unmarshal :: stdjson.unmarshal
parse :: stdjson.parse
parse_string :: stdjson.parse_string
parse_value :: stdjson.parse_value
make_parser :: stdjson.make_parser
make_parser_from_string :: stdjson.make_parser_from_string
advance_token :: stdjson.advance_token
unquote_string :: stdjson.unquote_string
destroy_value :: stdjson.destroy_value
validate_value :: stdjson.validate_value
