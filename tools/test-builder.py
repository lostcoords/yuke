#!/usr/bin/env python3
"""Test the package version rules without a Rust compile."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
COMPILER = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
root = Path.cwd()
args = sys.argv[1:]
if Path(sys.argv[0]).name == "git":
    if args[0] == "rev-parse":
        print("1234567890abcdef1234567890abcdef12345678")
    elif args[0] == "status":
        pass
    elif args[0] == "show":
        print("1704153600")
    else:
        sys.exit("unexpected Git command")
else:
    if args[0] == "metadata":
        print(json.dumps({"packages": [{"name": "yuke", "version": os.environ.get("PACKAGE_VERSION", "1.2.3")}],
                          "target_directory": str(root / "target")}))
    elif args[0] == "build":
        target = args[args.index("--target") + 1]
        binary = root / "target" / target / "release/yuke"
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_text("#!/bin/sh\nprintf 'yuke " + os.environ["YUKE_BUILD_VERSION"] + "\\n'\n")
        binary.chmod(0o755)
    else:
        sys.exit("unexpected Cargo command")
'''


class BuilderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="yuke-builder-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.commands = self.root / "commands"
        self.commands.mkdir()
        for name in ("cargo", "git"):
            executable = self.commands / name
            executable.write_text(COMPILER)
            executable.chmod(0o755)
        for name in ("tools/package.py", "LICENSE.md"):
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, destination)
        for name in ("crates/js/modules", "crates/js/types", "crates/protocol/bindings", "docs", "skills"):
            shutil.copytree(ROOT / name, self.root / name)
        shutil.copy2(ROOT / "crates/js/tsconfig.json", self.root / "crates/js/tsconfig.json")
        self.environment = dict(os.environ, PATH=str(self.commands) + os.pathsep + os.environ["PATH"])
        self.output = self.root / "target/packages"

    def build(self, environment, *args):
        return subprocess.run([sys.executable, str(self.root / "tools/package.py"),
                               "--target", "aarch64-apple-darwin", *args], env=environment,
                              text=True, capture_output=True, timeout=30)

    def test_nightly_identity_uses_the_commit_date_and_drops_release_suffixes(self):
        for version in ("1.2.3-dev+build.5", "1.2.3+build.5"):
            with self.subTest(version=version):
                environment = dict(self.environment, PACKAGE_VERSION=version)
                result = self.build(environment, "--nightly")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                with tarfile.open(self.output / "yuke-aarch64-macos.tar.gz") as archive:
                    self.assertEqual(json.load(archive.extractfile("lib/yuke/build.json"))["version"],
                                     "1.2.3-nightly.20240102+1234567890ab")
                    self.assertEqual(archive.extractfile("bin/yuke").read(),
                                     b"#!/bin/sh\nprintf 'yuke 1.2.3-nightly.20240102+1234567890ab\\n'\n")

    def test_tagged_builds_require_a_matching_release_version(self):
        cases = [({}, ["--tag", "v9.9.9"], "the tag must be v plus"),
                 ({}, ["--tag", "v1.2.3", "--nightly"], "the tag must be v plus"),
                 ({"PACKAGE_VERSION": "1.2.3-dev"}, ["--tag", "v1.2.3-dev"], "without -dev")]
        for values, args, message in cases:
            with self.subTest(arguments=args, environment=values):
                result = self.build(dict(self.environment, **values), *args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
                self.assertEqual(list(self.output.glob("*.tar.gz")), [])
        for version in ("1.2.3", "1.2.3+build-dev.5"):
            with self.subTest(version=version):
                result = self.build(dict(self.environment, PACKAGE_VERSION=version), "--tag", "v" + version)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                with tarfile.open(self.output / "yuke-aarch64-macos.tar.gz") as archive:
                    self.assertEqual(archive.extractfile("bin/yuke").read(),
                                     ("#!/bin/sh\nprintf 'yuke " + version + "\\n'\n").encode())



if __name__ == "__main__":
    unittest.main(verbosity=2)
