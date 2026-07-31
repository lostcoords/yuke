/*
package schema is the build-time generator for the machine-readable wire schema. It parses
the Odin sources of `src/wire` with `core:odin/parser` and builds one in-memory protocol
model, which later steps emit as `wire.json` (the meta-model SDK generators consume) and
`schema.json` (JSON Schema 2020-12).

Runtime `core:reflect` sees neither doc comments nor the `@bounded` / `@fixed` markers, so
an AST pass is the only route to a complete model.

Every discrepancy is a hard failure. The artifact other languages will trust must never be
a guess: a missing dispatch case would ship an SDK that cannot call a method, and a stale
bounds marker would ship a schema that accepts frames the daemon rejects. The diagnostic
sink accumulates rather than stopping at the first problem, because a stale marker and a
missing case are usually the same edit.

Facts the wire package states only inside procedure bodies — the method/params/result
linkage, broadcast/payload, and delivery class — are recovered by matching AST nodes,
never by scanning source text. Required-nullable members are declared on fields and
cross-checked against the dedicated emitter helpers.
Text matching would encode incidental things like a decoder's parameter name and fail
silently; a silently wrong entry is worse than no artifact.

Allocation policy: this is a one-shot tool that parses, reports, and exits. Everything it
allocates lives until the process ends, and the model borrows its strings from the parsed
file buffers rather than copying them. Nothing is freed on purpose.

The package is layered as:

  - `model.odin`: the protocol model — the single shape both artifacts are emitted from.
  - `diag.odin`: the accumulating diagnostic sink.
  - `source.odin`: loading and parsing the package, plus the doc-line and procedure indexes
    the AST does not provide directly.
  - `astutil.odin`: structural matching over parsed bodies — call sites, collection caps,
    switch clauses.
  - `consts.odin`: resolving `LIMITS` and the top-level integer constants that bounds
    markers name.
  - `types.odin`: the type graph — structs, unions, enums paired with their wire tables,
    and the scalar newtypes.
  - `registry.odin`: the five dispatch switches that hold the method and broadcast
    registries.
  - `check.odin`: the bounds cross-check between declared markers and enforced bounds, and
    the referential-integrity and `$ref`-resolution gates.
  - `artifact.odin`: the model rendered as `wire.json`, plus the drift check against the
    committed copy.
  - `jsonschema.odin`: the model rendered as JSON Schema 2020-12.
*/
package schema
