package main

import "core:testing"

@(test)
test_provider_args_never_accept_a_key_value :: proc(t: ^testing.T) {
    options, ok := provider_args_parse({"set-key", "openai"})
    testing.expect(t, ok, "set-key accepts only the provider id")
    testing.expect_value(t, options.action, Provider_Action.Set_Key)
    testing.expect_value(t, options.provider_id, "openai")

    _, key_in_argv := provider_args_parse({"set-key", "openai", "secret"})
    testing.expect(t, !key_in_argv, "a key value in argv is rejected")
}

@(test)
test_provider_args_cover_list_and_remove :: proc(t: ^testing.T) {
    listed, list_ok := provider_args_parse({"list"})
    testing.expect(t, list_ok, "list has no arguments")
    testing.expect_value(t, listed.action, Provider_Action.List)

    removed, remove_ok := provider_args_parse({"remove-key", "anthropic"})
    testing.expect(t, remove_ok, "remove-key needs one provider id")
    testing.expect_value(t, removed.action, Provider_Action.Remove_Key)
    testing.expect_value(t, removed.provider_id, "anthropic")
}
