# AGENTS.md

The Rust workspace of the yuke coding agent.

Write in ASD-STE100: one meaning per word, active voice, simple tense, one instruction per sentence.
Look up APIs on the internet and in this tree. Do not guess.

The project is pre-release. Break an API when a better design needs it. Do not keep the old shape. Do not add a shim or a deprecation path.
Fix the cause, not the symptom. Rewrite code when the rewrite is simpler.
Do not add a rule that fights this.

## Development

Rust 1.99. Run every tool through mise: `mise exec -- cargo ...`.

Before you finish:

```sh
mise exec -- cargo fmt --all -- --check
mise exec -- cargo clippy --all-targets --all-features -- -D warnings
mise exec -- cargo test --all-features
mise exec -- env RUSTDOCFLAGS=-Dwarnings cargo doc --no-deps --all-features
mise exec -- tsc -p crates/js/tsconfig.json
mise exec -- biome ci --error-on-warnings
```

Ask the user before you add a dependency.

## Code

- A comment says why, in one or two lines. Docs say what an item does, not how it came to be.
- Use full words in names.
- Do not discard a fallible result with `let _ =`. Propagate with `?` or handle it.

## Tests

- Name a test after the behavior it protects.
- Do not add a test that restates a type or a constant. Add a test to pin an invariant.
- Test observable behavior with independent expectations.
- Make negative tests reach the intended guard.
