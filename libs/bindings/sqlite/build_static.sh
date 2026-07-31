#!/usr/bin/env bash
# Build libs/bindings/sqlite/bin/sqlite3.{a,lib} from the official amalgamation.
# Used on Windows (required) and available on Unix if you want a static archive.
# Re-running is a no-op once the archive exists; FORCE=1 rebuilds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
AMAL_DIR="$ROOT/amalgamation"
BIN_DIR="$ROOT/bin"
YEAR="${SQLITE_YEAR:-2025}"
VER="${SQLITE_VER:-3490100}"
SHA256="${SQLITE_SHA256:-6cebd1d8403fc58c30e93939b246f3e6e58d0765a5cd50546f16c00fd805d2c3}"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) LIB="$BIN_DIR/sqlite3.lib" ;;
  *) LIB="$BIN_DIR/sqlite3.a" ;;
esac

if [[ -f "$LIB" && -z "${FORCE:-}" ]]; then
  echo "sqlite: bin/$(basename "$LIB") is up to date"
  exit 0
fi

mkdir -p "$AMAL_DIR" "$BIN_DIR"

if [[ ! -f "$AMAL_DIR/sqlite3.c" ]]; then
  zip="sqlite-amalgamation-${VER}.zip"
  url="https://www.sqlite.org/${YEAR}/${zip}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "fetching $url"
  curl -fsSL "$url" -o "$tmp/$zip"
  if command -v shasum >/dev/null 2>&1; then
    echo "${SHA256}  $tmp/$zip" | shasum -a 256 -c -
  elif command -v sha256sum >/dev/null 2>&1; then
    echo "${SHA256}  $tmp/$zip" | sha256sum -c -
  else
    echo "warning: no sha256 tool; skipping checksum" >&2
  fi
  unzip -q -o "$tmp/$zip" -d "$tmp"
  src_dir="$(find "$tmp" -maxdepth 1 -type d -name 'sqlite-amalgamation-*' | head -1)"
  cp "$src_dir/sqlite3.c" "$src_dir/sqlite3.h" "$AMAL_DIR/"
  [[ -f "$src_dir/sqlite3ext.h" ]] && cp "$src_dir/sqlite3ext.h" "$AMAL_DIR/"
fi

CFLAGS=(
  -O2
  -DSQLITE_THREADSAFE=1
  -DSQLITE_OMIT_LOAD_EXTENSION
  -DSQLITE_DEFAULT_MEMSTATUS=0
  -DSQLITE_DQS=0
)

CC="${CC:-}"
if [[ -z "$CC" ]]; then
  for c in clang gcc cc; do
    if command -v "$c" >/dev/null 2>&1; then
      CC="$c"
      break
    fi
  done
fi
if [[ -z "$CC" ]]; then
  echo "error: no C compiler found (set CC=)" >&2
  exit 1
fi

AR="${AR:-ar}"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    # Prefer MSVC when available; fall back to clang/gcc producing .a (lld-link can use it).
    if command -v cl >/dev/null 2>&1 && command -v lib >/dev/null 2>&1; then
      echo "compiling amalgamation with MSVC → bin/sqlite3.lib"
      (cd "$AMAL_DIR" && cl /nologo /c /O2 \
        /DSQLITE_THREADSAFE=1 \
        /DSQLITE_OMIT_LOAD_EXTENSION \
        /DSQLITE_DEFAULT_MEMSTATUS=0 \
        /DSQLITE_DQS=0 \
        sqlite3.c /Fo:"$BIN_DIR/sqlite3.obj")
      lib /nologo "$BIN_DIR/sqlite3.obj" /OUT:"$BIN_DIR/sqlite3.lib"
      rm -f "$BIN_DIR/sqlite3.obj"
    else
      echo "compiling amalgamation with $CC → bin/sqlite3.lib (llvm-ar)"
      "$CC" -c "${CFLAGS[@]}" "$AMAL_DIR/sqlite3.c" -o "$BIN_DIR/sqlite3.o"
      if command -v llvm-ar >/dev/null 2>&1; then
        llvm-ar rcs "$BIN_DIR/sqlite3.lib" "$BIN_DIR/sqlite3.o"
      else
        "$AR" rcs "$BIN_DIR/sqlite3.lib" "$BIN_DIR/sqlite3.o"
      fi
      rm -f "$BIN_DIR/sqlite3.o"
    fi
    ;;
  *)
    echo "compiling amalgamation with $CC → bin/sqlite3.a"
    "$CC" -c "${CFLAGS[@]}" "$AMAL_DIR/sqlite3.c" -o "$BIN_DIR/sqlite3.o"
    "$AR" rcs "$BIN_DIR/sqlite3.a" "$BIN_DIR/sqlite3.o"
    rm -f "$BIN_DIR/sqlite3.o"
    # Windows cross-check may look for .lib; not required for Unix system link.
    ;;
esac

echo "done."
