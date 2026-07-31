# No system libquickjs exists anywhere, so this archive must be built before the
# bindings link. build_static.sh owns the version pin.
.PHONY: static rebuild clean

static:
	bash build_static.sh

rebuild:
	FORCE=1 bash build_static.sh

clean:
	rm -rf bin
	rm -f amalgamation/quickjs-amalgam.c amalgamation/quickjs.h amalgamation/quickjs-libc.h
