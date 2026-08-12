package daemon

import "core:log"
import "core:nbio"
import "core:os"
import "core:path/filepath"
import "core:testing"

import "libs:testsupport"
import catalog "src:daemon/catalog"
import js "src:js"
import wire "src:wire"

@(private = "file")
provider_test_write :: proc(t: ^testing.T, dir: string, name: string, source: string) {
    path, join_err := filepath.join({dir, name}, context.temp_allocator)
    testing.expect(t, join_err == nil, "the provider fixture path joins")
    testing.expect_value(t, os.write_entire_file(path, transmute([]byte)source), nil)
}

@(private = "file")
provider_test_start :: proc(t: ^testing.T, name: string, source: string, d: ^Daemon) -> Error {
    context.logger = log.nil_logger()

    root := test_make_dir(name)
    defer os.remove_all(root)
    provider_test_write(t, root, JS_ENTRY_FILE, source)

    return start(d, nbio.current_thread_event_loop(), {host = "127.0.0.1", port = 0, js_root = root})
}

@(private = "file")
provider_test_error :: proc(t: ^testing.T, name: string, source: string) -> Error {
    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    d: Daemon
    err := provider_test_start(t, name, source, &d)
    if err == .None {
        test_teardown(&d)
    }

    return err
}

// Multiple defineProvider calls contribute providers, and registration remains open across a
// top-level await. Finalization preserves the captured value, not later JavaScript object mutations.
@(test)
test_define_provider_builds_an_owned_registry_after_entry_settles :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    root := test_make_dir("provider-valid")
    defer os.remove_all(root)

    provider_test_write(
        t,
        root,
        JS_ENTRY_FILE,
        `
            import { defineProvider } from "yuke:daemon"

            const definition = { modelsDev: "openai" }
            defineProvider("openai", definition)
            definition.modelsDev = "anthropic"

            await Promise.resolve()

            defineProvider("company", {
                name: "Company",
                baseUrl: "https://models.company.test/v1",
                protocol: "openai-chat",
                credentialEnv: ["COMPANY_API_KEY", "COMPANY_TOKEN"],
                modelsDev: "company",
                models: [{
                    id: "company-code",
                    upstreamId: "company-code-v2",
                    name: "Company Code",
                    contextWindow: 128000,
                    maxOutputTokens: 16000,
                    reasoningLevels: ["low", "medium", "high"],
                    reasoningFormat: "openrouter-effort",
                    reasoningReplay: "reasoning-content",
                    supportsVision: false,
                    supportsTools: true,
                    supportsTemperature: true,
                    cost: { input: 1.25, output: 5, cacheRead: 0.25, cacheWrite: 0 },
                }],
                modelOverrides: [{
                    id: "gpt-5",
                    reasoningLevels: ["low", "high"],
                }],
            })

            defineProvider("local", {
                baseUrl: "http://127.0.0.1:11434/v1",
                protocol: "openai-chat",
            })
        `,
    )

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    d: Daemon
    saved_logger := context.logger
    context.logger = log.nil_logger()
    err := start(&d, nbio.current_thread_event_loop(), {host = "127.0.0.1", port = 0, js_root = root})
    context.logger = saved_logger
    if !testing.expect_value(t, err, Error.None) {
        return
    }
    defer test_teardown(&d)

    testing.expect_value(t, len(d.providers.captures), 0)
    testing.expect_value(t, d.providers.capture_bytes, 0)
    testing.expect(t, !d.providers.registration_open, "provider registration closes after entry evaluation")
    if !testing.expect_value(t, len(d.providers.definitions), 3) {
        return
    }

    imported := d.providers.definitions[0]
    testing.expect_value(t, imported.id, "openai")
    testing.expect_value(t, imported.models_dev, "openai")
    testing.expect(t, !imported.has_endpoint, "a models.dev overlay needs no local endpoint")

    company := d.providers.definitions[1]
    testing.expect_value(t, company.id, "company")
    testing.expect_value(t, company.name, "Company")
    testing.expect_value(t, company.base_url, "https://models.company.test/v1")
    testing.expect_value(t, company.protocol, wire.Provider_Protocol.Openai_Chat)
    testing.expect(t, company.has_endpoint, "the company provider has a complete endpoint")
    testing.expect_value(t, company.models_dev, "company")
    if testing.expect_value(t, len(company.credential_env), 2) {
        testing.expect_value(t, company.credential_env[0], "COMPANY_API_KEY")
        testing.expect_value(t, company.credential_env[1], "COMPANY_TOKEN")
    }
    if testing.expect_value(t, len(company.models), 1) {
        model := company.models[0]
        testing.expect_value(t, model.id, "company/company-code")
        testing.expect_value(t, model.upstream_id, "company-code-v2")
        testing.expect_value(t, model.name, "Company Code")
        testing.expect_value(t, model.context_window, u64(128000))
        testing.expect_value(t, model.max_output_tokens, u64(16000))
        testing.expect_value(t, model.default_reasoning, "medium")
        testing.expect_value(t, model.reasoning_format, catalog.Reasoning_Format.Openrouter_Effort)
        testing.expect_value(t, model.reasoning_replay, catalog.Reasoning_Replay.Reasoning_Content)
        testing.expect(t, !model.supports_vision, "vision support is captured exactly")
        testing.expect(t, model.supports_tools, "tool support is captured exactly")
        testing.expect(t, model.supports_temperature, "temperature support is captured exactly")
        testing.expect_value(t, model.cost.input, 1.25)
        testing.expect_value(t, model.cost.output, 5.0)
        testing.expect_value(t, model.cost.cache_read, 0.25)
        testing.expect_value(t, model.cost.cache_write, 0.0)
    }

    if testing.expect_value(t, len(company.overrides), 1) {
        override := company.overrides[0]
        testing.expect_value(t, override.id, "company/gpt-5")
        testing.expect_value(t, override.default_reasoning, "high")
        if testing.expect_value(t, len(override.reasoning_levels), 2) {
            testing.expect_value(t, override.reasoning_levels[0], "low")
            testing.expect_value(t, override.reasoning_levels[1], "high")
        }
    }

    local := d.providers.definitions[2]
    testing.expect_value(t, local.id, "local")
    testing.expect(t, local.has_endpoint, "a custom provider may be endpoint-only")
    testing.expect_value(t, local.models_dev, "")
}

Provider_Invalid_Case :: struct {
    name:   string,
    source: string,
}

// Every nested object is closed, model definitions are complete, and references are checked only
// after all calls have been captured. These are configuration errors, not half-applied defaults.
@(test)
test_define_provider_rejects_invalid_registries :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    cases := []Provider_Invalid_Case {
        {
            "provider-duplicate",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("openai", { modelsDev: "openai" })
                defineProvider("openai", { modelsDev: "openai" })
            `,
        },
        {
            "provider-secret-field",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("openai", { modelsDev: "openai", apiKey: "must-not-survive" })
            `,
        },
        {
            "provider-header-field",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("openai", { modelsDev: "openai", headers: { Authorization: "secret" } })
            `,
        },
        {
            "provider-no-source",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("company", { name: "Company" })
            `,
        },
        {
            "provider-half-endpoint",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("local", { baseUrl: "http://127.0.0.1:11434/v1" })
            `,
        },
        {
            "provider-invalid-endpoint",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("local", { baseUrl: "file:///tmp/models", protocol: "openai-chat" })
            `,
        },
        {
            "provider-invalid-protocol",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("local", { baseUrl: "http://127.0.0.1:11434/v1", protocol: "openai-completions" })
            `,
        },
        {
            "provider-invalid-id",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("bad/provider", { modelsDev: "openai" })
            `,
        },
        {
            "provider-invalid-models-dev-id",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("company", { modelsDev: "bad/provider" })
            `,
        },
        {
            "provider-model-map",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("local", {
                    baseUrl: "http://127.0.0.1:11434/v1", protocol: "openai-chat",
                    models: { gpt: {} },
                })
            `,
        },
        {
            "provider-incomplete-model",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("local", {
                    baseUrl: "http://127.0.0.1:11434/v1", protocol: "openai-chat",
                    models: [{ id: "gpt" }],
                })
            `,
        },
        {
            "provider-duplicate-model",
            `
                import { defineProvider } from "yuke:daemon"
                const model = id => ({
                    id, upstreamId: id, name: id,
                    contextWindow: 128000, maxOutputTokens: 16000,
                    reasoningLevels: [],
                    supportsVision: false, supportsTools: true, supportsTemperature: true,
                    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
                })
                defineProvider("local", {
                    baseUrl: "http://127.0.0.1:11434/v1", protocol: "openai-chat",
                    models: [model("gpt"), model("gpt")],
                })
            `,
        },
        {
            "provider-unsafe-token-count",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("local", {
                    baseUrl: "http://127.0.0.1:11434/v1", protocol: "openai-chat",
                    models: [{
                        id: "gpt", upstreamId: "gpt", name: "GPT",
                        contextWindow: 9007199254740992, maxOutputTokens: 1,
                        reasoningLevels: [],
                        supportsVision: false, supportsTools: true, supportsTemperature: true,
                        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
                    }],
                })
            `,
        },
        {
            "provider-zero-token-count",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("local", {
                    baseUrl: "http://127.0.0.1:11434/v1", protocol: "openai-chat",
                    models: [{
                        id: "gpt", upstreamId: "gpt", name: "GPT",
                        contextWindow: 128000, maxOutputTokens: 0,
                        reasoningLevels: [],
                        supportsVision: false, supportsTools: true, supportsTemperature: true,
                        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
                    }],
                })
            `,
        },
        {
            "provider-public-model-id-too-long",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("local", {
                    baseUrl: "http://127.0.0.1:11434/v1", protocol: "openai-chat",
                    models: [{
                        id: "x".repeat(128), upstreamId: "gpt", name: "GPT",
                        contextWindow: 128000, maxOutputTokens: 16000,
                        reasoningLevels: [],
                        supportsVision: false, supportsTools: true, supportsTemperature: true,
                        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
                    }],
                })
            `,
        },
        {
            "provider-default-reasoning-field",
            `
                import { defineProvider } from "yuke:daemon"
                const M = { id: "gpt", upstreamId: "gpt", name: "GPT", contextWindow: 128000, maxOutputTokens: 16000, reasoningLevels: [], supportsVision: false, supportsTools: true, supportsTemperature: true, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }
                defineProvider("local", {
                    baseUrl: "http://127.0.0.1:11434/v1", protocol: "openai-chat",
                    models: [{ ...M, defaultReasoning: "" }],
                })
            `,
        },
        {
            "provider-reasoning-budget-field",
            `
                import { defineProvider } from "yuke:daemon"
                const M = { id: "gpt", upstreamId: "gpt", name: "GPT", contextWindow: 128000, maxOutputTokens: 16000, reasoningLevels: [], supportsVision: false, supportsTools: true, supportsTemperature: true, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }
                defineProvider("local", {
                    baseUrl: "http://127.0.0.1:11434/v1", protocol: "openai-chat",
                    models: [{ ...M, reasoningBudget: { min: 1, max: 2 } }],
                })
            `,
        },
        {
            "provider-missing-temperature",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("local", {
                    baseUrl: "http://127.0.0.1:11434/v1", protocol: "openai-chat",
                    models: [{
                        id: "gpt", upstreamId: "gpt", name: "GPT",
                        contextWindow: 128000, maxOutputTokens: 16000,
                        reasoningLevels: [],
                        supportsVision: false, supportsTools: true,
                        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
                    }],
                })
            `,
        },
        {
            "provider-unknown-reasoning-format",
            `
                import { defineProvider } from "yuke:daemon"
                const M = { id: "gpt", upstreamId: "gpt", name: "GPT", contextWindow: 128000, maxOutputTokens: 16000, reasoningLevels: [], supportsVision: false, supportsTools: true, supportsTemperature: true, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }
                defineProvider("local", {
                    baseUrl: "http://127.0.0.1:11434/v1", protocol: "openai-chat",
                    models: [{ ...M, reasoningFormat: "bogus" }],
                })
            `,
        },
        {
            "provider-unknown-reasoning-replay",
            `
                import { defineProvider } from "yuke:daemon"
                const M = { id: "gpt", upstreamId: "gpt", name: "GPT", contextWindow: 128000, maxOutputTokens: 16000, reasoningLevels: [], supportsVision: false, supportsTools: true, supportsTemperature: true, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }
                defineProvider("local", {
                    baseUrl: "http://127.0.0.1:11434/v1", protocol: "openai-chat",
                    models: [{ ...M, reasoningReplay: "bogus" }],
                })
            `,
        },
        {
            "provider-incompatible-reasoning-format",
            `
                import { defineProvider } from "yuke:daemon"
                const M = { id: "gpt", upstreamId: "gpt", name: "GPT", contextWindow: 128000, maxOutputTokens: 16000, reasoningLevels: [], supportsVision: false, supportsTools: true, supportsTemperature: true, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }
                defineProvider("local", {
                    baseUrl: "http://127.0.0.1:11434/v1", protocol: "openai-chat",
                    models: [{ ...M, reasoningFormat: "anthropic-adaptive" }],
                })
            `,
        },
        {
            "provider-models-without-endpoint",
            `
                import { defineProvider } from "yuke:daemon"
                const M = { id: "gpt", upstreamId: "gpt", name: "GPT", contextWindow: 128000, maxOutputTokens: 16000, reasoningLevels: [], supportsVision: false, supportsTools: true, supportsTemperature: true, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }
                defineProvider("openai", { modelsDev: "openai", models: [M] })
            `,
        },
        {
            "provider-overrides-without-models-dev",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("local", {
                    baseUrl: "http://127.0.0.1:11434/v1", protocol: "openai-chat",
                    modelOverrides: [{ id: "gpt", reasoningLevels: [] }],
                })
            `,
        },
        {
            "provider-duplicate-override",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("openai", {
                    modelsDev: "openai",
                    modelOverrides: [{ id: "gpt", reasoningLevels: [] }, { id: "gpt", reasoningLevels: [] }],
                })
            `,
        },
        {
            "provider-override-unknown-field",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("openai", {
                    modelsDev: "openai",
                    modelOverrides: [{ id: "gpt", reasoningLevels: [], name: "nope" }],
                })
            `,
        },
        {
            "provider-negative-cost",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("local", {
                    baseUrl: "http://127.0.0.1:11434/v1", protocol: "openai-chat",
                    models: [{
                        id: "gpt", upstreamId: "gpt", name: "GPT",
                        contextWindow: 128000, maxOutputTokens: 16000,
                        reasoningLevels: [],
                        supportsVision: false, supportsTools: true, supportsTemperature: true,
                        cost: { input: -1, output: 0, cacheRead: 0, cacheWrite: 0 },
                    }],
                })
            `,
        },
        {
            "provider-duplicate-env",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("openai", {
                    modelsDev: "openai",
                    credentialEnv: ["OPENAI_API_KEY", "OPENAI_API_KEY"],
                })
            `,
        },
    }

    for test_case in cases {
        testing.expect_value(t, provider_test_error(t, test_case.name, test_case.source), Error.Invalid_Options)
    }
}

@(test)
test_define_provider_rejects_bad_call_shapes :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    cases := []Provider_Invalid_Case {
        {
            "provider-non-string-id",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider(42, { modelsDev: "openai" })
            `,
        },
        {
            "provider-non-object-definition",
            `
                import { defineProvider } from "yuke:daemon"
                defineProvider("openai", 42)
            `,
        },
        {
            "provider-unserializable-definition",
            `
                import { defineProvider } from "yuke:daemon"
                const definition = { modelsDev: "openai" }
                definition.self = definition
                defineProvider("openai", definition)
            `,
        },
    }

    for test_case in cases {
        testing.expect_value(t, provider_test_error(t, test_case.name, test_case.source), Error.Script_Failed)
    }
}

// A JavaScript catch cannot turn an exhausted native capture allocator into a successful entry.
// Each failure point must also release any earlier allocation from the same capture.
@(test)
test_define_provider_reports_native_capture_oom :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)
    context.logger = log.nil_logger()

    for fail_at := 0; fail_at < 3; fail_at += 1 {
        root := test_make_dir("provider-capture-oom")

        nbio.acquire_thread_event_loop()
        loop := nbio.current_thread_event_loop()

        d: Daemon
        start_err := start(&d, loop, {host = "127.0.0.1", port = 0, js_root = root})
        if !testing.expect_value(t, start_err, Error.None) {
            nbio.release_thread_event_loop()
            os.remove_all(root)
            return
        }

        provider_test_write(
            t,
            root,
            JS_ENTRY_FILE,
            `
                import { defineProvider } from "yuke:daemon"
                try {
                    defineProvider("openai", { modelsDev: "openai" })
                } catch {}
            `,
        )

        owned_allocator := d.allocator
        failing: testsupport.Failing_Allocator
        testsupport.failing_allocator_init(&failing, owned_allocator, fail_at)
        d.allocator = testsupport.failing_allocator(&failing)

        evaluated, entry_err := js_run_entry(&d, owned_allocator)
        testing.expect(t, !evaluated, "a native capture OOM cannot evaluate successfully")
        testing.expect_value(t, entry_err, Error.Out_Of_Memory)
        testing.expect(t, d.providers.capture_oom, "the native capture OOM is latched")
        testing.expect_value(t, len(d.providers.captures), 0)
        testing.expect_value(t, d.providers.capture_bytes, 0)

        d.allocator = owned_allocator
        test_teardown(&d)
        nbio.release_thread_event_loop()
        os.remove_all(root)
    }
}

// The native export remains importable because the daemon keeps one shared runtime, but its
// mutation window is permanently closed once yuked.js has settled.
@(test)
test_define_provider_rejects_registration_after_start :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    d: Daemon
    err := provider_test_start(
        t,
        "provider-late",
        `
            import { defineProvider } from "yuke:daemon"
            defineProvider("openai", { modelsDev: "openai" })
        `,
        &d,
    )
    if !testing.expect_value(t, err, Error.None) {
        return
    }
    defer test_teardown(&d)

    context.logger = log.nil_logger()
    accepted := js.eval_module(
        &d.js,
        "late-provider.js",
        `
            import { defineProvider } from "yuke:daemon"
            defineProvider("anthropic", { modelsDev: "anthropic" })
        `,
        context.temp_allocator,
    )
    testing.expect(t, !accepted, "provider registration closes after startup")
    testing.expect_value(t, len(d.providers.definitions), 1)
    testing.expect_value(t, d.providers.definitions[0].id, "openai")
}
