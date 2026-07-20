# Odin resolved via mise (see .mise.toml). Override with `make ODIN=/path/to/odin`.
ODIN ?= mise exec -- odin
ODINFMT ?= odinfmt
COLLECTION := -collection:src=src -collection:libs=libs

.PHONY: test test-wire test-ws fmt clean

# Run all wire package tests.
test-wire:
	@mkdir -p build
	$(ODIN) test src/wire $(COLLECTION) -out:build/wire_test.bin

# Run the yuke-agnostic WebSocket client tests.
test-ws:
	@mkdir -p build
	$(ODIN) test libs/websocket $(COLLECTION) -out:build/ws_test.bin

test: test-wire test-ws

# Format all Odin sources in place (config in odinfmt.json).
fmt:
	$(ODINFMT) -w src
	$(ODINFMT) -w libs

clean:
	rm -rf build
