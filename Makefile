# Odin resolved via mise (see .mise.toml). Override with `make ODIN=/path/to/odin`.
ODIN ?= mise exec -- odin
ODINFMT ?= odinfmt
COLLECTION := -collection:src=src -collection:libs=libs

.PHONY: test test-wire test-ws test-http test-client test-daemon test-support test-ui test-term check-windows fmt clean

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


# Run the client package tests (session replica).
test-client:
	@mkdir -p build
	$(ODIN) test src/client $(COLLECTION) -out:build/client_test.bin

# Run the daemon package tests (front-door routes plus the hello exchange).
test-daemon:
	@mkdir -p build
	$(ODIN) test src/daemon $(COLLECTION) -out:build/daemon_test.bin


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

test: test-wire test-ws test-http test-client test-daemon test-support test-ui test-term

# Cross-compile type-check of the Windows arms from the host (no Windows machine
# needed). `odin check` defaults to an executable package, so -no-entry-point is
# required for these library packages; it also compiles *_test.odin, so POSIX-only
# test files must carry `#+build` tags. This is a compile gate, not a test run;
# kept out of `make test` deliberately.
check-windows:
	$(ODIN) check src/ui $(COLLECTION) -target:windows_amd64 -no-entry-point
	$(ODIN) check src/term $(COLLECTION) -target:windows_amd64 -no-entry-point

# Format all Odin sources in place (config in odinfmt.json).
fmt:
	$(ODINFMT) -w src
	$(ODINFMT) -w libs

clean:
	rm -rf build
