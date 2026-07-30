# libcurl (Windows static link)

Unix builds link the system `libcurl`. Windows builds link a **static**
`libs/curl/bin/curl.lib`, built on a Windows host from a pinned upstream
release. The foreign import lives in `libs/curl/c.odin` as `@(private)`
(`bin/curl.lib`), together with the system libraries a static archive cannot
carry itself: `ws2_32`, `crypt32`, `secur32`, `bcrypt`, `advapi32`.

## Build

From an "x64 Native Tools Command Prompt for VS", with `cmake` on PATH:

```bat
libs\curl\build_static.bat
```

The script fetches the pinned tarball, verifies its SHA256, and configures a
HTTP(S)-only build: TLS through **Schannel** (system trust store, no bundled CA
bundle, no OpenSSL to track), and every other protocol libcurl can speak
compiled out. Artifacts land in `libs/curl/bin/` and `libs/curl/upstream/`, both gitignored —
the `.lib` is never checked in.

`CURL_STATICLIB` is a C-header concern only (it turns off `__declspec(dllimport)`);
this binding declares its own symbols and needs no such define.

## Pin

`build_static.bat` pins the version and SHA256, overridable through the
`CURL_VER` / `CURL_SHA256` environment variables. Bump both together.

## Known gap

The pinned configuration builds without nghttp2, so Windows gets HTTP/1.1 only.
`CURLOPT_PIPEWAIT` stays set and is simply inert there. Unix uses the system
libcurl and keeps HTTP/2 wherever the distribution enabled it.
