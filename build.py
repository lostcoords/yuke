#!/usr/bin/env python3
"""Build, test, format, and lint driver for yuke-odin.

Every Odin invocation is derived from the PACKAGES table, so a package is declared
once and every gate that consumes it picks it up.
"""

import filecmp
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "build"

ODIN = shlex.split(os.environ.get("ODIN", "mise exec -- odin"))
ODINFMT = shlex.split(os.environ.get("ODINFMT", "odinfmt"))
CONFIG = f"-config:{ROOT / 'odinfmt.json'}"

COLLECTIONS = ["-collection:src=src", "-collection:libs=libs", "-collection:tools=tools"]

# No -vet-tabs (odinfmt formats with spaces), no -vet-unused-procedures (libs/ may
# carry unused surface).
LINT = ["-vet", "-strict-style", "-warnings-as-errors"]

# Covers what a test takes from context.allocator, not an arena fed from its own memory.
TEST_DEFINES = ["-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true"]

BINDINGS = ("quickjs", "sqlite")

FMT_DIRS = ("src", "libs", "tools")

AGGREGATE = "tests"


class Package:
    def __init__(
        self,
        name,
        path,
        note="",
        tests=True,
        in_aggregate=True,  # reached by tests/all.odin
        windows_test=False,  # runs under test-windows
        needs=(),
    ):
        self.name = name
        self.path = path
        self.note = note
        self.tests = tests
        self.in_aggregate = in_aggregate
        self.windows_test = windows_test
        self.needs = needs

    def __str__(self):
        return f"{self.name:<13} {self.path:<23} {self.note}"


PACKAGES = (
    Package("auth", "src/auth", "private credential store and provider OAuth adapters"),
    Package("secret", "src/secret", "explicit cleanup for owned secret buffers"),
    Package("wire", "src/wire", "protocol types, JSON codec, registries, validation"),
    Package("paths", "src/paths", "shared platform config-directory resolution"),
    Package("client", "src/client", "session replica"),
    Package("daemon", "src/daemon", "front-door routes plus the initialize exchange"),
    Package("js", "src/js", "shared QuickJS host plus the yuke:fs module"),
    Package("store", "src/daemon/store", "open/configure plus the migration runner"),
    Package(
        "store-queries",
        "src/daemon/store/queries",
        "generated Params/Row structs and the Queries registry, decoupled from Store",
    ),
    Package("provider", "src/provider", "requests, decoding, turn lifecycle, retry policy"),
    Package("relay", "src/relay", "link envelope, control-plane client, Noise session, dial/pump"),
    Package("term", "src/term", "terminal input, session, and the nbio driver", windows_test=True),
    Package("ui", "src/term/ui", "cells, grapheme pool, paint", windows_test=True),
    Package("tui", "src/tui", "interactive terminal client: term drive, QuickJS host, ui paint", needs=("quickjs",)),
    Package(
        "yuke",
        "src/yuke",
        "unified binary: dispatch over the tui, daemon, and login subcommands",
        in_aggregate=False,
        needs=BINDINGS,
    ),
    Package("ws", "libs/websocket", "both drivers plus the sans-I/O core"),
    Package("http", "libs/http", "sans-I/O HTTP"),
    Package("http-server", "libs/http/server", "nbio front door"),
    Package("http-sse", "libs/http/sse", "sans-I/O SSE parser"),
    Package("offload", "libs/offload", "worker pool: blocking work off the reactor"),
    Package("testsupport", "libs/testsupport", "shared test helpers"),
    Package("curl", "libs/bindings/curl", "libcurl binding and multi-on-nbio driver"),
    Package("quickjs", "libs/bindings/quickjs", "QuickJS binding", needs=("quickjs",)),
    Package("sqlite", "libs/bindings/sqlite", "binding over system libsqlite3"),
    Package("gen", "tools/gen", "shared diagnostics and write-or-check codegen helpers", in_aggregate=False),
    Package("schema", "tools/schema", "wire.json and wire.schema.json generator", in_aggregate=False),
    Package("sqlgen", "tools/sqlgen", "queries_gen.odin generator from the real schema", in_aggregate=False),
)

BY_NAME = {p.name: p for p in PACKAGES}

COMMANDS = {}


def command(fn):
    COMMANDS[fn.__name__.replace("_", "-")] = fn

    return fn


def run(argv, env=None, cwd=None, quiet=False):
    print("$ " + " ".join(shlex.quote(a) for a in argv), flush=True)

    result = subprocess.run(
        argv,
        cwd=cwd or ROOT,
        env={**os.environ, **env} if env else None,
        stdout=subprocess.DEVNULL if quiet else None,
    )

    if result.returncode != 0:
        sys.exit(result.returncode)


def odin(*args):
    BUILD.mkdir(exist_ok=True)
    run([*ODIN, *args, *COLLECTIONS, *LINT])


def binding_build(name, force=False):
    directory = ROOT / "libs/bindings" / name
    # cwd is not searched for executables on Windows, so the .bat needs its full path.
    argv = [str(directory / "build_static.bat")] if os.name == "nt" else ["bash", "build_static.sh"]

    run(argv, cwd=directory, env={"FORCE": "1"} if force else None)


def ensure(needs):
    for name in needs:
        binding_build(name)


def test_package(package):
    ensure(package.needs)
    odin("test", package.path, *TEST_DEFINES, f"-out:{BUILD / package.name}_test.bin")


def resolve(names):
    for name in names:
        if name not in BY_NAME:
            sys.exit(f"unknown package '{name}'; run './build.py help' for the list")

        yield BY_NAME[name]


@command
def test(args):
    """run tests; no argument runs every package"""
    if args:
        for package in resolve(args):
            if not package.tests:
                sys.exit(f"package '{package.name}' has no tests")

            test_package(package)

        return

    ensure(("quickjs",))
    odin("test", AGGREGATE, "-all-packages", *TEST_DEFINES, f"-out:{BUILD / 'all_test.bin'}")

    for package in PACKAGES:
        if package.tests and not package.in_aggregate:
            test_package(package)


@command
def yuke(args):
    """build the unified binary into build/yuke"""
    package = BY_NAME["yuke"]
    ensure(package.needs)

    # Odin defaults to -o:minimal, which costs this paint loop ~8x.
    odin("build", package.path, "-o:speed", f"-out:{BUILD / 'yuke'}")


def install_dir(args):
    if args:
        return Path(args[0]).expanduser()

    prefix = os.environ.get("PREFIX")
    if prefix:
        return Path(prefix).expanduser() / "bin"

    return Path.home() / ".local" / "bin"


@command
def install(args):
    """build and install yuke into ~/.local/bin (a dir arg or $PREFIX/bin overrides)"""
    yuke([])

    dest_dir = install_dir(args)
    dest_dir.mkdir(parents=True, exist_ok=True)
    # Atomic rename, not in-place copy: overwriting a running daemon's mapped binary makes
    # macOS SIGKILL the next exec. os.replace gives dest a fresh inode.
    dest = dest_dir / "yuke"
    staged = dest_dir / ".yuke.new"
    shutil.copy2(BUILD / "yuke", staged)
    staged.chmod(0o755)
    os.replace(staged, dest)
    print(f"installed yuke -> {dest}")

    if str(dest_dir) not in os.environ.get("PATH", "").split(os.pathsep):
        print(f"note: {dest_dir} is not on PATH")


@command
def test_windows(args):
    """run the Windows-arm tests on a Windows Odin (WIN_ODIN)"""
    # A Scoop shim works from WSL. -out: must be a native path, or it resolves against
    # the UNC cwd (LNK1104); the tests inherit pipes, so console arms take their
    # not-a-console branches. Linking that way does not work at all: Odin passes archives
    # as `//wsl.localhost/...`, which link.exe reads as an option and ignores (LNK4044).
    shims = sorted(Path("/mnt/c/Users").glob("*/scoop/shims/odin.exe"))
    win_odin = os.environ.get("WIN_ODIN") or (str(shims[0]) if shims else "")

    if not win_odin:
        sys.exit("no Windows odin found; set WIN_ODIN=/mnt/c/path/to/odin.exe (and WIN_OUT)")

    # The Windows account name need not match the WSL one, so never guess it.
    user = Path(win_odin).parents[2].name
    out = os.environ.get("WIN_OUT", rf"C:\Users\{user}\AppData\Local\Temp")

    for package in PACKAGES:
        if package.windows_test:
            run([win_odin, "test", package.path, *COLLECTIONS, *LINT, *TEST_DEFINES,
                 rf"-out:{out}\yuke_{package.name}_test.exe"])


@command
def schema(args):
    """regenerate schema/wire.json and schema/wire.schema.json from src/wire"""
    (ROOT / "schema").mkdir(exist_ok=True)
    odin("build", BY_NAME["schema"].path, f"-out:{BUILD / 'schema.bin'}")
    run([str(BUILD / "schema.bin")])


@command
def schema_check(args):
    """verify the committed schema artifacts still describe src/wire"""
    odin("build", BY_NAME["schema"].path, f"-out:{BUILD / 'schema.bin'}")
    run([str(BUILD / "schema.bin"), "--check", "--quiet"])
    test(["schema"])


STORE_MIGRATIONS = ROOT / "src/daemon/store/migrations"
STORE_QUERIES = ROOT / "src/daemon/store/queries"
STORE_QUERIES_GEN = STORE_QUERIES / "queries_gen.odin"


@command
def sql(args):
    """regenerate queries_gen.odin from the real schema"""
    odin("build", BY_NAME["sqlgen"].path, f"-out:{BUILD / 'sqlgen.bin'}")
    run(
        [
            str(BUILD / "sqlgen.bin"),
            "--migrations",
            str(STORE_MIGRATIONS),
            "--queries",
            str(STORE_QUERIES),
            "--queries-out",
            str(STORE_QUERIES_GEN),
        ]
    )
    # sqlgen writes raw field lists; odinfmt owns column alignment, same as every
    # other Odin source, so the committed file is always the formatted one.
    run([*ODINFMT, CONFIG, "-w", str(STORE_QUERIES_GEN)], quiet=True)


@command
def sql_check(args):
    """verify the committed generated store code still describes the real schema"""
    odin("build", BY_NAME["sqlgen"].path, f"-out:{BUILD / 'sqlgen.bin'}")

    with tempfile.TemporaryDirectory() as tmp:
        candidate = Path(tmp) / "queries_gen.odin"
        run(
            [
                str(BUILD / "sqlgen.bin"),
                "--migrations",
                str(STORE_MIGRATIONS),
                "--queries",
                str(STORE_QUERIES),
                "--queries-out",
                str(candidate),
                "--quiet",
            ]
        )
        run([*ODINFMT, CONFIG, "-w", str(candidate)], quiet=True)

        if not STORE_QUERIES_GEN.exists():
            sys.exit(f"{STORE_QUERIES_GEN}: nothing committed to check against; run './build.py sql' and commit it")

        if not filecmp.cmp(STORE_QUERIES_GEN, candidate, shallow=False):
            sys.exit(f"{STORE_QUERIES_GEN}: stale — run './build.py sql' and commit the result")

    test(["sqlgen"])


@command
def fmt(args):
    """format all Odin sources in place"""
    for directory in FMT_DIRS:
        run([*ODINFMT, CONFIG, "-w", directory])


@command
def fmt_check(args):
    """report unformatted sources without touching the working tree"""
    unformatted = []

    with tempfile.TemporaryDirectory() as tmp:
        mirror = Path(tmp)

        for directory in FMT_DIRS:
            for source in (ROOT / directory).rglob("*.odin"):
                target = mirror / source.relative_to(ROOT)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)

        run([*ODINFMT, CONFIG, "-w", str(mirror)], quiet=True)

        for formatted in mirror.rglob("*.odin"):
            relative = formatted.relative_to(mirror)

            if not filecmp.cmp(ROOT / relative, formatted, shallow=False):
                unformatted.append(str(relative))

    if unformatted:
        print("unformatted (run './build.py fmt'):", file=sys.stderr)

        for path in sorted(unformatted):
            print(f"  {path}", file=sys.stderr)

        sys.exit(1)

    print(f"{len(FMT_DIRS)} trees formatted")


@command
def deps(args):
    """build the C archives: QuickJS everywhere, SQLite for Windows linking"""
    # libcurl is absent on purpose: system:curl on Unix, build_static.bat on Windows.
    ensure(BINDINGS)


@command
def deps_rebuild(args):
    """refetch and recompile both archives, ignoring what is built"""
    for name in BINDINGS:
        binding_build(name, force=True)


@command
def clean(args):
    """remove build/; binding archives survive, use deps-rebuild for those"""
    shutil.rmtree(BUILD, ignore_errors=True)


@command
def setup(args):
    """point git at the tracked hooks in .githooks"""
    run(["git", "config", "core.hooksPath", ".githooks"])


@command
def help(args):
    """show this message"""
    print(__doc__.strip())
    print("\nCommands:")

    for name, fn in COMMANDS.items():
        print(f"  {name:<13} {fn.__doc__}")

    print("\nPackages (for `test`):")

    for package in PACKAGES:
        if package.tests:
            print(f"  {package}")

    print("\nEnvironment: ODIN, ODINFMT, WIN_ODIN, WIN_OUT")


def main():
    name, *args = sys.argv[1:] or ["help"]

    if name not in COMMANDS:
        sys.exit(f"unknown command '{name}'; run './build.py help' for the list")

    COMMANDS[name](args)


if __name__ == "__main__":
    main()
