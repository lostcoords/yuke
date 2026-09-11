The Zig tests run these files inside the yuke QuickJS host.
Each named Zig test owns a fresh host and its teardown.
A file has no test entry point until a Zig test calls it.

Use `test_support.eval` for an ES module.
Use `check(name, condition)` or `equal(actual, expected)` from `yuke:test` for JS assertions.
The helper reports the file path and the JS fault.
Test modules stay outside the production module table.

Use Zig assertions for native state, allocation, paint output, and resource ownership.
A test with native I/O must pump the host until its operation settles.
A JS module must not await native I/O before the Zig owner can pump it.
Use `test_support.evalScript` for a script that shares globals with an earlier fixture.
Keep completion and cancellation checks in the Zig test for these scripts.

The directories group files by contract.
Some files provide setup or a later phase of one Zig test.
Keep the setup and the expected result in the language that owns the state.

Run all tests with `zig build test`.
Run the process and JS host tests with `zig build test-js`.
Select named cases with `zig build test-js -Dtest-filter='plugin scope'`.
