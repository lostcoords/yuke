@echo off
REM Build libs\sqlite\bin\sqlite3.lib from the official amalgamation (MSVC).
REM Run from an "x64 Native Tools Command Prompt for VS".
setlocal EnableExtensions

set ROOT=%~dp0
set AMAL=%ROOT%amalgamation
set BIN=%ROOT%bin
if not exist "%BIN%" mkdir "%BIN%"

if not exist "%AMAL%\sqlite3.c" (
  echo error: amalgamation missing. Run build_static.sh once to fetch, or place sqlite3.c/h in amalgamation\
  exit /b 1
)

where cl >nul 2>nul
if errorlevel 1 (
  echo error: cl.exe not on PATH. Open an x64 Native Tools Command Prompt.
  exit /b 1
)

echo Compiling amalgamation with MSVC...
cl /nologo /c /O2 /DSQLITE_THREADSAFE=1 /DSQLITE_OMIT_LOAD_EXTENSION /DSQLITE_DEFAULT_MEMSTATUS=0 /DSQLITE_DQS=0 "%AMAL%\sqlite3.c" /Fo"%BIN%\sqlite3.obj"
if errorlevel 1 exit /b 1
lib /nologo "%BIN%\sqlite3.obj" /OUT:"%BIN%\sqlite3.lib"
if errorlevel 1 exit /b 1
del "%BIN%\sqlite3.obj"
echo Wrote %BIN%\sqlite3.lib
exit /b 0
