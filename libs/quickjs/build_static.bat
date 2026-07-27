@echo off
REM Build libs\quickjs\bin\windows_amd64\quickjs.lib from the QuickJS-NG amalgamation (MSVC).
REM Run from an "x64 Native Tools Command Prompt for VS".
setlocal EnableExtensions

set ROOT=%~dp0
set AMAL=%ROOT%amalgamation
set BIN=%ROOT%bin\windows_amd64
if not exist "%BIN%" mkdir "%BIN%"

if not exist "%AMAL%\quickjs-amalgam.c" (
  echo error: amalgamation missing. Run build_static.sh once to fetch, or place quickjs-amalgam.c/quickjs.h in amalgamation\
  exit /b 1
)

where cl >nul 2>nul
if errorlevel 1 (
  echo error: cl.exe not on PATH. Open an x64 Native Tools Command Prompt.
  exit /b 1
)

REM QJS_BUILD_LIBC is deliberately omitted: quickjs-libc would give scripts their
REM own filesystem and process access, bypassing the daemon's IO primitives.
echo Compiling amalgamation with MSVC...
cl /nologo /c /O2 /std:c11 /experimental:c11atomics /DNDEBUG "%AMAL%\quickjs-amalgam.c" /Fo"%BIN%\quickjs.obj"
if errorlevel 1 exit /b 1
lib /nologo "%BIN%\quickjs.obj" /OUT:"%BIN%\quickjs.lib"
if errorlevel 1 exit /b 1
del "%BIN%\quickjs.obj"
echo Wrote %BIN%\quickjs.lib
exit /b 0
