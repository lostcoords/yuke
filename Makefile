# Odin resolved via mise (see .mise.toml). Override with `make ODIN=/path/to/odin`.
ODIN ?= mise exec -- odin
ODINFMT ?= odinfmt
COLLECTION := -collection:src=src -collection:libs=libs

.PHONY: schema schema-check schema-test setup test test-wire test-ws test-http test-sse test-offload test-client test-daemon test-store test-provider test-support test-ui test-term test-sqlite test-quickjs test-curl check-windows fmt clean deps deps-rebuild

# Each binding owns its Makefile and version pin. `static` is a no-op once the
# archive exists, so test targets can depend on it.
QUICKJS := $(MAKE) -C libs/bindings/quickjs
SQLITE := $(MAKE) -C libs/bindings/sqlite


# Run all wire package tests.
test-wire:
	@mkdir -p build
	$(ODIN) test src/wire $(COLLECTION) -out:build/wire_test.bin

# Run the yuke-agnostic WebSocket tests (both drivers plus the sans-IO core).
test-ws:
	@mkdir -p build
	$(ODIN) test libs/websocket $(COLLECTION) -out:build/ws_test.bin

# Run the sans-I/O HTTP tests and the nbio front-door tests.
test-http:
	@mkdir -p build
	$(ODIN) test libs/http $(COLLECTION) -out:build/http_test.bin
	$(ODIN) test libs/http/server $(COLLECTION) -out:build/http_server_test.bin

# Run the sans-I/O SSE parser tests.
test-sse:
	@mkdir -p build
	$(ODIN) test libs/http/sse $(COLLECTION) -out:build/http_sse_test.bin

# Run the libcurl binding and the multi-on-nbio driver tests. Needs the libcurl
# development package (Unix links `system:curl`); the integration tests stream
# from `libs/http/server` over 127.0.0.1, so nothing reaches the network.
test-curl:
	@mkdir -p build
	$(ODIN) test libs/bindings/curl $(COLLECTION) -out:build/curl_test.bin


# Run the worker-pool tests (blocking work off the reactor).
test-offload:
	@mkdir -p build
	$(ODIN) test libs/offload $(COLLECTION) -out:build/offload_test.bin

# Run the client package tests (session replica).
test-client:
	@mkdir -p build
	$(ODIN) test src/client $(COLLECTION) -out:build/client_test.bin

# Run the daemon package tests (front-door routes plus the initialize exchange).
test-daemon:
	@mkdir -p build
	$(ODIN) test src/daemon $(COLLECTION) -out:build/daemon_test.bin


# Run the event store tests (open/configure plus the migration runner).
test-store:
	@mkdir -p build
	$(ODIN) test src/daemon/store $(COLLECTION) -out:build/store_test.bin

# Run the provider package tests (auth headers, error mapping, retry policy).
test-provider:
	@mkdir -p build
	$(ODIN) test src/provider $(COLLECTION) -out:build/provider_test.bin

# Run the testsupport package tests.
test-support:
	@mkdir -p build
	$(ODIN) test libs/testsupport $(COLLECTION) -out:build/support_test.bin

# Run the ui package tests.
test-ui:
	@mkdir -p build
	$(ODIN) test src/ui $(COLLECTION) -out:build/ui_test.bin

# Run the term package tests.
test-term:
	@mkdir -p build
	$(ODIN) test src/term $(COLLECTION) -out:build/term_test.bin

# Run the minimal SQLite binding tests (system libsqlite3 on Darwin/Linux).
test-sqlite:
	@mkdir -p build
	$(ODIN) test libs/bindings/sqlite $(COLLECTION) -out:build/sqlite_test.bin


# Run the QuickJS binding tests. Unlike SQLite there is no system library, so the
# host archive is built first if it is missing.
test-quickjs:
	@mkdir -p build
	$(QUICKJS) static
	$(ODIN) test libs/bindings/quickjs $(COLLECTION) -out:build/quickjs_test.bin


# `tests` imports libs:bindings/quickjs, so the host archive must exist.
test:
	@mkdir -p build
	$(QUICKJS) static
	$(ODIN) test tests $(COLLECTION) -all-packages -out:build/all_test.bin

# QuickJS everywhere, SQLite for Windows linking. libcurl has no build here — it
# links system:curl on Unix and its Windows archive comes from build_static.bat.
deps:
	$(QUICKJS) static
	$(SQLITE) static

# Refetch and recompile both, ignoring what is already built.
deps-rebuild:
	$(QUICKJS) rebuild
	$(SQLITE) rebuild


# Cross-compile type-check of the Windows arms from the host (no Windows machine
# needed). `odin check` defaults to an executable package, so -no-entry-point is
# required for these library packages; it also compiles *_test.odin, so POSIX-only
# test files must carry `#+build` tags. This is a compile gate, not a test run;
# kept out of `make test` deliberately.
# libs/bindings/sqlite's Windows arm foreign-imports bin/sqlite3.lib (built via
# `make deps` on a Windows host); check does not link, so the archive
# need not exist for this gate.
check-windows:
	$(ODIN) check src/ui $(COLLECTION) -target:windows_amd64 -no-entry-point
	$(ODIN) check src/term $(COLLECTION) -target:windows_amd64 -no-entry-point
	$(ODIN) check src/daemon/store $(COLLECTION) -target:windows_amd64 -no-entry-point
	$(ODIN) check libs/bindings/sqlite $(COLLECTION) -target:windows_amd64 -no-entry-point
	$(ODIN) check libs/bindings/quickjs $(COLLECTION) -target:windows_amd64 -no-entry-point
	$(ODIN) check libs/bindings/curl $(COLLECTION) -target:windows_amd64 -no-entry-point

# Regenerate both artifacts from src/wire: schema/wire.json (the meta-model SDK generators
# read) and schema/wire.schema.json (JSON Schema 2020-12, for validators and docs). The
# generator cross-checks every bounds marker against the validator that enforces it, so a
# protocol discrepancy exits non-zero before anything is written.
schema:
	@mkdir -p build schema
	$(ODIN) build tools/schema $(COLLECTION) -out:build/schema.bin
	./build/schema.bin

# Verify the committed artifacts still describe src/wire. Regeneration is a pure function of
# the wire sources, so a mismatch means they were not regenerated after a protocol change.
# Keep this out of `make test`: it gates the artifacts, not the code.
schema-check:
	@mkdir -p build
	$(ODIN) build tools/schema $(COLLECTION) -out:build/schema.bin
	./build/schema.bin --check --quiet
	$(MAKE) schema-test

schema-test:
	@mkdir -p build
	$(ODIN) test tools/schema $(COLLECTION) -out:build/schema_test.bin

# One-time setup for a fresh clone: point git at the tracked hooks in .githooks.
setup:
	git config core.hooksPath .githooks

# Format all Odin sources in place (config in odinfmt.json).
fmt:
	$(ODINFMT) -w src
	$(ODINFMT) -w libs
	$(ODINFMT) -w tools

clean:
	rm -rf build
