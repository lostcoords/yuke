# Required for Windows linking; optional on Unix, which links `system:sqlite3`.
# build_static.sh owns the version pin.
.PHONY: static rebuild clean

static:
	bash build_static.sh

rebuild:
	FORCE=1 bash build_static.sh

clean:
	rm -rf bin
	rm -f amalgamation/sqlite3.c amalgamation/sqlite3.h amalgamation/sqlite3ext.h
