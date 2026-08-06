package sqlgen

import "core:testing"

@(test)
test_options_parse_defaults :: proc(t: ^testing.T) {
    opts, ok := options_parse({})
    testing.expect(t, ok)
    testing.expect_value(t, opts.migrations, "src/daemon/store/migrations")
    testing.expect_value(t, opts.queries_out, "src/daemon/store/queries/queries_gen.odin")
    testing.expect(t, !opts.check)
    testing.expect(t, !opts.quiet)
}

@(test)
test_options_parse_overrides_every_flag :: proc(t: ^testing.T) {
    opts, ok := options_parse({"--migrations", "m", "--queries-out", "o", "--check", "--quiet"})
    testing.expect(t, ok)
    testing.expect_value(t, opts.migrations, "m")
    testing.expect_value(t, opts.queries_out, "o")
    testing.expect(t, opts.check)
    testing.expect(t, opts.quiet)
}

@(test)
test_options_parse_rejects_an_unknown_flag :: proc(t: ^testing.T) {
    _, ok := options_parse({"--nope"})
    testing.expect(t, !ok, "an unrecognized flag is refused, not ignored")
}

@(test)
test_options_parse_rejects_a_flag_missing_its_value :: proc(t: ^testing.T) {
    _, ok := options_parse({"--migrations"})
    testing.expect(t, !ok, "a value-taking flag with nothing after it is refused")

    _, ok2 := options_parse({"--queries-out"})
    testing.expect(t, !ok2, "a value-taking flag with nothing after it is refused")
}
