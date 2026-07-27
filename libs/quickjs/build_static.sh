#!/usr/bin/env bash
# Build libs/quickjs/bin/<os>_<arch>/quickjs.{a,lib} from the QuickJS-NG
# amalgamation. Required on every platform: unlike SQLite there is no system
# libquickjs to link against anywhere.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
AMAL_DIR="$ROOT/amalgamation"
# QuickJS-NG v0.15.1 — keep in sync with Makefile QUICKJS_VER / QUICKJS_SHA256.
VER="${QUICKJS_VER:-v0.15.1}"
SHA256="${QUICKJS_SHA256:-d4dbf9cbf7a855c790d3c4c468ac45b00371d56fd8ae26e1aaa1d336efc589d8}"

mkdir -p "$AMAL_DIR"

# Skip the fetch when the amalgamation is already present, so vendoring it into
# the tree later is a drop-in with no change to this script.
if [[ ! -f "$AMAL_DIR/quickjs-amalgam.c" ]]; then
  zip="quickjs-amalgam.zip"
  url="https://github.com/quickjs-ng/quickjs/releases/download/${VER}/${zip}"
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
  cp "$tmp/quickjs-amalgam.c" "$tmp/quickjs.h" "$AMAL_DIR/"
  [[ -f "$tmp/quickjs-libc.h" ]] && cp "$tmp/quickjs-libc.h" "$AMAL_DIR/"
fi

# _GNU_SOURCE is required on glibc for tm_gmtoff and alloca; the amalgamation
# only defines it for itself under QJS_BUILD_LIBC, which we deliberately do not
# set — quickjs-libc would hand scripts their own filesystem and process access,
# bypassing the daemon's IO primitives.
CFLAGS=(
  -O2
  -std=c11
  -fno-strict-aliasing
  -DNDEBUG
  -D_GNU_SOURCE
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

# Target directory must match the foreign import ladder in c.odin.
case "$(uname -m)" in
  x86_64 | amd64) ARCH="amd64" ;;
  aarch64 | arm64) ARCH="arm64" ;;
  *)
    echo "error: unsupported arch $(uname -m); quickjs bindings are 64-bit only" >&2
    exit 1
    ;;
esac

case "$(uname -s)" in
  Linux) OS="linux" ;;
  Darwin) OS="darwin" ;;
  MINGW* | MSYS* | CYGWIN* | Windows_NT) OS="windows" ;;
  *)
    echo "error: unsupported OS $(uname -s)" >&2
    exit 1
    ;;
esac

BIN_DIR="$ROOT/bin/${OS}_${ARCH}"
mkdir -p "$BIN_DIR"

if [[ "$OS" == "windows" ]]; then
  # Prefer MSVC; fall back to clang/gcc producing an archive lld-link accepts.
  if command -v cl >/dev/null 2>&1 && command -v lib >/dev/null 2>&1; then
    echo "compiling amalgamation with MSVC → bin/${OS}_${ARCH}/quickjs.lib"
    (cd "$AMAL_DIR" && cl /nologo /c /O2 /std:c11 /experimental:c11atomics /DNDEBUG \
      quickjs-amalgam.c /Fo:"$BIN_DIR/quickjs.obj")
    lib /nologo "$BIN_DIR/quickjs.obj" /OUT:"$BIN_DIR/quickjs.lib"
    rm -f "$BIN_DIR/quickjs.obj"
  else
    echo "compiling amalgamation with $CC → bin/${OS}_${ARCH}/quickjs.lib"
    "$CC" -c "${CFLAGS[@]}" "$AMAL_DIR/quickjs-amalgam.c" -o "$BIN_DIR/quickjs.o"
    if command -v llvm-ar >/dev/null 2>&1; then
      llvm-ar rcs "$BIN_DIR/quickjs.lib" "$BIN_DIR/quickjs.o"
    else
      "$AR" rcs "$BIN_DIR/quickjs.lib" "$BIN_DIR/quickjs.o"
    fi
    rm -f "$BIN_DIR/quickjs.o"
  fi
else
  echo "compiling amalgamation with $CC → bin/${OS}_${ARCH}/quickjs.a"
  "$CC" -c "${CFLAGS[@]}" "$AMAL_DIR/quickjs-amalgam.c" -o "$BIN_DIR/quickjs.o"
  "$AR" rcs "$BIN_DIR/quickjs.a" "$BIN_DIR/quickjs.o"
  rm -f "$BIN_DIR/quickjs.o"
fi

echo "done."
