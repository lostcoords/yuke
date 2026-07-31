# Unix links `system:curl`; the Windows archive is built on a Windows host by
# build_static.bat, which owns its own version pin.
.PHONY: static rebuild clean

static:
	@echo "error: libs/bindings/curl has no static build on this platform." >&2
	@echo "       Unix links system:curl (install the libcurl development package)." >&2
	@echo "       Windows archives are built on a Windows host via build_static.bat." >&2
	@exit 1

rebuild: static

clean:
	rm -rf upstream
	rm -f bin/*.a bin/*.lib bin/*.dll bin/*.exp bin/*.pdb
