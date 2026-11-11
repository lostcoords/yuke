# AGENTS.md

The Rust workspace of the yuke coding agent.

The codebase is yours: what it's for and how it's built are your call, and you'll keep building on it.

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
for manifest in crates/*/Cargo.toml; do mise exec -- cargo check --manifest-path "$manifest" --all-targets || break; done
```

The last line builds each crate with its own features only, so a feature that another crate turns on hides no gap.

Ask the user before you add a dependency.

Write commit messages in imperative English.

## Code

- A comment says why, in one or two lines. Docs say what an item does, not how it came to be.
- Use full words in names.
  A registration gives a remover: `add*` adds an independent one, and `set*` replaces the one before it.
  A callback option `on*` is one that the core calls. A callback option `request*` is one that a plugin calls.
  A method that waits for a state starts with a verb: `waitFor*`. A bare adjective is a state.
  A name says who gets the effect when two targets are possible: `notifyModel`, `closeForAll`.
  One word has one meaning across modules. A `message` is what a user sends in a chat. A `notice` is what a user reads.
  Follow Rust conventions.
  Use short generic parameters (`T`, `F`).
  Use standard trait parameter names (`f: &mut Formatter`).
  Use common ecosystem names (`ctx`, `args`, `_ms`).
- Do not discard a fallible result with `let _ =`. Propagate with `?` or handle it.
- In TypeScript, give each parameter a plain name. Prefer dot notation to preserve context.
  Destructure only when it improves clarity or captures values that must stay fixed. Do not destructure parameters.
- Validate unknown values once at the boundary that owns them. Pass typed values inward.
  Do not repeat checks that a schema, constructor, or internal type already guarantees.
- Do not extract single-use helpers preemptively. Inline the logic at the call site unless the helper is reused,
  hides a genuinely complex boundary, or has a clear independent name that improves the caller.
- Before adding complexity for a speculative or vanishingly unlikely race or security edge case, explain the concrete
  failure mode, likelihood, and complexity cost to the user and get their buy-in.
  Do not silently expand scope for theoretical robustness.
- Give each error one of two shapes. Never mix them, or a printer of the chain shows a text twice.
  - A context error writes its own text and returns the cause from `source`.
  - A transparent error writes the text of its inner error and returns the `source` of that inner error. It can add
    facts after that text.
- A trait error that the library only reports is `Box<dyn Error + Send + Sync>`.
  Use a concrete type only when the library acts on its kind.

## Tests

- Name a test after the behavior it protects.
- Do not add a test that restates a type or a constant. Add a test to pin an invariant.
- Test observable behavior with independent expectations.
- Make negative tests reach the intended guard.
