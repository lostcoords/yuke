# Odin resolved via mise (see .mise.toml). Override with `make ODIN=/path/to/odin`.
ODIN ?= mise exec -- odin
ODINFMT ?= odinfmt
COLLECTION := -collection:src=src -collection:libs=libs

.PHONY: test test-wire test-ws test-http test-offload test-client test-daemon test-store test-support test-ui test-term test-sqlite test-quickjs check-windows fmt clean sqlite-static quickjs-static

# Pinned SQLite amalgamation (Windows static link). Keep in sync with build_static.sh.
SQLITE_YEAR ?= 2025
SQLITE_VER ?= 3490100
SQLITE_SHA256 ?= 6cebd1d8403fc58c30e93939b246f3e6e58d0765a5cd50546f16c00fd805d2c3

# Pinned QuickJS-NG amalgamation (static link on every platform — there is no
# system libquickjs anywhere). Keep in sync with libs/quickjs/build_static.sh.
QUICKJS_VER ?= v0.15.1
QUICKJS_SHA256 ?= d4dbf9cbf7a855c790d3c4c468ac45b00371d56fd8ae26e1aaa1d336efc589d8


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
	$(ODIN) test libs/sqlite $(COLLECTION) -out:build/sqlite_test.bin


# Run the QuickJS binding tests. Unlike SQLite there is no system library, so
# `make quickjs-static` must have produced the host archive first.
test-quickjs:
	@mkdir -p build
	$(ODIN) test libs/quickjs $(COLLECTION) -out:build/quickjs_test.bin


test:
	@mkdir -p build
	$(ODIN) test tests $(COLLECTION) -all-packages -out:build/all_test.bin

# Fetch the pinned amalgamation and build a static archive under libs/sqlite/bin/.
# Required for Windows linking; optional on Unix (tests use system libsqlite3).
sqlite-static:
	SQLITE_YEAR=$(SQLITE_YEAR) SQLITE_VER=$(SQLITE_VER) SQLITE_SHA256=$(SQLITE_SHA256) \
	bash libs/sqlite/build_static.sh

# Fetch the pinned amalgamation and build libs/quickjs/bin/<os>_<arch>/quickjs.{a,lib}.
# Required on every platform before libs/quickjs will link. Each host builds its own.
quickjs-static:
	QUICKJS_VER=$(QUICKJS_VER) QUICKJS_SHA256=$(QUICKJS_SHA256) \
	bash libs/quickjs/build_static.sh


# Cross-compile type-check of the Windows arms from the host (no Windows machine
# needed). `odin check` defaults to an executable package, so -no-entry-point is
# required for these library packages; it also compiles *_test.odin, so POSIX-only
# test files must carry `#+build` tags. This is a compile gate, not a test run;
# kept out of `make test` deliberately.
# libs/sqlite's Windows arm foreign-imports bin/sqlite3.lib (built via
# `make sqlite-static` on a Windows host); check does not link, so the archive
# need not exist for this gate.
check-windows:
	$(ODIN) check src/ui $(COLLECTION) -target:windows_amd64 -no-entry-point
	$(ODIN) check src/term $(COLLECTION) -target:windows_amd64 -no-entry-point
	$(ODIN) check src/daemon/store $(COLLECTION) -target:windows_amd64 -no-entry-point
	$(ODIN) check libs/sqlite $(COLLECTION) -target:windows_amd64 -no-entry-point
	$(ODIN) check libs/quickjs $(COLLECTION) -target:windows_amd64 -no-entry-point

# Format all Odin sources in place (config in odinfmt.json).
fmt:
	$(ODINFMT) -w src
	$(ODINFMT) -w libs

clean:
	rm -rf build
