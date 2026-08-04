@echo off
REM Build libs\bindings\curl\bin\curl.lib: a static, Schannel-backed, HTTP(S)-only libcurl.
REM Run from an "x64 Native Tools Command Prompt for VS". Requires cmake on PATH.
setlocal EnableExtensions

set ROOT=%~dp0
set UPSTREAM=%ROOT%upstream
set BIN=%ROOT%bin
if not exist "%BIN%" mkdir "%BIN%"
if not exist "%UPSTREAM%" mkdir "%UPSTREAM%"

REM Pinned release. Bump the version and the hash together.
if "%CURL_VER%"=="" set CURL_VER=8.21.0
if "%CURL_SHA256%"=="" set CURL_SHA256=aa1b66a70eace83dc624508745646c08ae561de512ab403adffb93ac87fc72e6

set TARBALL=%UPSTREAM%\curl-%CURL_VER%.tar.xz
set TREE=%UPSTREAM%\curl-%CURL_VER%

where cmake >nul 2>nul
if errorlevel 1 (
  echo error: cmake.exe not on PATH.
  exit /b 1
)

where cl >nul 2>nul
if errorlevel 1 (
  echo error: cl.exe not on PATH. Open an x64 Native Tools Command Prompt.
  exit /b 1
)

if not exist "%TARBALL%" (
  echo Fetching curl %CURL_VER%...
  curl -sSL -o "%TARBALL%" "https://curl.se/download/curl-%CURL_VER%.tar.xz"
  if errorlevel 1 exit /b 1
)

echo Verifying SHA256...
set "GOT="
for /f "skip=1 tokens=1" %%h in ('certutil -hashfile "%TARBALL%" SHA256') do (
  if not defined GOT set GOT=%%h
)
if /i not "%GOT%"=="%CURL_SHA256%" (
  echo error: SHA256 mismatch. expected %CURL_SHA256%, got %GOT%
  exit /b 1
)

if not exist "%TREE%" (
  echo Extracting...
  tar -xf "%TARBALL%" -C "%UPSTREAM%"
  if errorlevel 1 exit /b 1
)

REM HTTP and HTTPS only, TLS through Schannel so there is no bundled CA store and
REM no OpenSSL to track. Everything else libcurl can speak is compiled out.
echo Configuring...
REM The CRT model must match Odin's, which links the static UCRT (`libucrt.lib`).
REM cmake defaults to the DLL runtime, and an archive built that way fails to link with
REM unresolved `__imp_*` CRT symbols.
cmake -S "%TREE%" -B "%TREE%\build" -G "NMake Makefiles" ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded ^
  -DBUILD_SHARED_LIBS=OFF ^
  -DBUILD_STATIC_LIBS=ON ^
  -DBUILD_CURL_EXE=OFF ^
  -DBUILD_TESTING=OFF ^
  -DBUILD_EXAMPLES=OFF ^
  -DCURL_USE_SCHANNEL=ON ^
  -DCURL_USE_OPENSSL=OFF ^
  -DCURL_USE_LIBSSH2=OFF ^
  -DCURL_USE_LIBPSL=OFF ^
  -DCURL_ZLIB=OFF ^
  -DCURL_BROTLI=OFF ^
  -DCURL_ZSTD=OFF ^
  -DUSE_NGHTTP2=OFF ^
  -DUSE_LIBIDN2=OFF ^
  -DCURL_DISABLE_FTP=ON ^
  -DCURL_DISABLE_LDAP=ON ^
  -DCURL_DISABLE_LDAPS=ON ^
  -DCURL_DISABLE_TELNET=ON ^
  -DCURL_DISABLE_DICT=ON ^
  -DCURL_DISABLE_FILE=ON ^
  -DCURL_DISABLE_TFTP=ON ^
  -DCURL_DISABLE_RTSP=ON ^
  -DCURL_DISABLE_POP3=ON ^
  -DCURL_DISABLE_IMAP=ON ^
  -DCURL_DISABLE_SMTP=ON ^
  -DCURL_DISABLE_SMB=ON ^
  -DCURL_DISABLE_GOPHER=ON ^
  -DCURL_DISABLE_MQTT=ON
if errorlevel 1 exit /b 1

echo Building...
cmake --build "%TREE%\build" --config Release --target libcurl_static
if errorlevel 1 exit /b 1

for /r "%TREE%\build" %%f in (libcurl.lib libcurl_a.lib) do (
  if exist "%%f" copy /y "%%f" "%BIN%\curl.lib" >nul
)

if not exist "%BIN%\curl.lib" (
  echo error: no static archive produced under %TREE%\build
  exit /b 1
)

echo Wrote %BIN%\curl.lib
exit /b 0
