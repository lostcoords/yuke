# yuke-testing

Test fixtures that the tests of several yuke crates share. The crate is not published. A crate lists it in its
`dev-dependencies`.

- `target`, `origin`, `definition`, `model`, and `model_of` make an Anthropic target at a test host, its origin, a tool
  definition, and a `ModelAccess` with no credential.
- `assert_in_order` checks that texts appear as JSON strings in a body, in order.
- `folder` makes a new empty folder for one test, below the temporary folder of the process.
- `git` runs Git as a test user with no hooks and no signing, and `commit_plugin` commits a plugin in a test
  repository.

A fixture that one crate alone uses stays in that crate. The scripted transport is `yuke_ai::scripted`, and the timer
that never waits is `yuke_engine::NoWait`.
