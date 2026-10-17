#!/usr/bin/env python3
"""Build a yuke installation archive."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parent.parent
TARGETS = {
    "x86_64-unknown-linux-musl": "x86_64-linux-musl",
    "aarch64-unknown-linux-musl": "aarch64-linux-musl",
    "x86_64-apple-darwin": "x86_64-macos",
    "aarch64-apple-darwin": "aarch64-macos",
}


def output(*command):
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def copy_typescript(source, destination, pattern="**/*.ts"):
    """Copy TS source without local editor files or other development state."""
    for path in sorted(source.glob(pattern)):
        if path.is_symlink():
            raise RuntimeError("package source must be a regular file: " + str(path))
        target = destination / path.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)


def source_state():
    """Detect source edits during a build, including new source files."""
    names = subprocess.check_output(
        ["git", "ls-files", "-co", "--exclude-standard", "-z", "--",
         "crates", ".cargo", "Cargo.toml", "Cargo.lock", "Cross.toml"],
        cwd=ROOT,
    ).split(b"\0")
    names.extend(os.fsencode(name) for name in (
        "LICENSE.md", ".mise.toml", ".mise.cross.toml", "mise.lock", "mise.cross.lock",
        "tools/package.py",
    ))
    for folder in ("crates/js/modules", "crates/js/types", "crates/protocol/bindings"):
        names.extend(os.fsencode(path.relative_to(ROOT)) for path in (ROOT / folder).rglob("*.ts"))
    value = hashlib.sha256()
    for name in sorted(set(names) - {b""}):
        path = ROOT / os.fsdecode(name)
        value.update(name + b"\0")
        value.update(path.read_bytes() if path.is_file() else b"<absent>")
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=TARGETS)
    parser.add_argument("--output", type=Path, default=ROOT / "target/packages")
    parser.add_argument("--nightly", action="store_true")
    parser.add_argument("--require-clean", action="store_true")
    parser.add_argument("--tag", help="Require v plus the Cargo package version")
    args = parser.parse_args()

    target = args.target
    if target is None:
        host = output("rustc", "-vV")
        target = next(line.removeprefix("host: ") for line in host.splitlines() if line.startswith("host: "))
        if target.endswith("-unknown-linux-gnu"):
            target = target.removesuffix("-gnu") + "-musl"
    if target not in TARGETS:
        parser.error("select one of the four supported release targets")

    before = source_state()
    metadata = json.loads(output("cargo", "metadata", "--no-deps", "--format-version=1", "--locked"))
    package = next(package for package in metadata["packages"] if package["name"] == "yuke")
    version = package["version"]
    if args.tag and (args.nightly or args.tag != "v" + version):
        parser.error("the tag must be v plus the Cargo package version, without --nightly")
    if args.tag and "-dev" in version.split("+", 1)[0]:
        parser.error("tagged releases need a version without -dev")
    commit = output("git", "rev-parse", "HEAD")
    dirty = bool(output("git", "status", "--porcelain", "--untracked-files=all"))
    if dirty and (args.require_clean or args.tag):
        parser.error("release packages require a clean working tree")
    if args.nightly:
        timestamp = int(output("git", "show", "-s", "--format=%ct", "HEAD"))
        date = datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc).strftime("%Y%m%d")
        version = version.split("+", 1)[0].split("-", 1)[0] + "-nightly." + date + "+" + commit[:12]
    if dirty:
        version += ".dirty" if "+" in version else "+dirty"

    environment = dict(os.environ, YUKE_BUILD_VERSION=version)
    builder = ["mise", "--env", "cross", "exec", "--", "cross"] if target.endswith("-linux-musl") else ["cargo"]
    subprocess.run(
        builder + ["build", "--locked", "--release", "--package", "yuke", "--target", target],
        cwd=ROOT, env=environment, check=True,
    )
    binary = Path(metadata["target_directory"]) / target / "release/yuke"
    destination = args.output.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / ("yuke-" + TARGETS[target] + ".tar.gz")
    with tempfile.TemporaryDirectory(prefix=".yuke-package-", dir=destination) as temporary:
        staging = Path(temporary)
        (staging / "bin").mkdir()
        shutil.copy2(binary, staging / "bin/yuke")
        library = staging / "lib/yuke"
        library.mkdir(parents=True)
        # Authors get only the public modules and the globals, so an internal import fails their type check too.
        copy_typescript(ROOT / "crates/js/modules", library / "modules", "*.ts")
        copy_typescript(ROOT / "crates/js/types", library / "types", "globals.d.ts")
        copy_typescript(ROOT / "crates/protocol/bindings", library / "protocol/bindings")
        shutil.copy2(ROOT / "crates/protocol/README.md", library / "protocol/README.md")
        shutil.copy2(ROOT / "LICENSE.md", library / "LICENSE.md")
        configuration = json.loads((ROOT / "crates/js/tsconfig.json").read_text())
        configuration["include"] = ["./modules/*.ts", "./protocol/bindings/**/*.ts"]
        configuration["files"] = ["./types/globals.d.ts"]
        configuration["compilerOptions"]["paths"]["yuke:protocol/*"] = ["./protocol/bindings/*.ts"]
        (library / "tsconfig.json").write_text(json.dumps(configuration, indent=2) + "\n")
        identity = {"format": 1, "version": version, "commit": commit, "target": target, "dirty": dirty}
        (library / "build.json").write_text(json.dumps(identity, indent=2) + "\n")
        pending = staging / archive.name
        with tarfile.open(pending, "w:gz") as package_archive:
            package_archive.add(staging / "bin", arcname="bin")
            package_archive.add(staging / "lib", arcname="lib")
        if before != source_state() or commit != output("git", "rev-parse", "HEAD"):
            raise RuntimeError("source changed during the build; build the package again")
        pending.replace(archive)
    print(archive)
    print(json.dumps(identity, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
