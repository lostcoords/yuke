#!/usr/bin/env python3
"""Test package input checks and concurrent output writes without a Rust compile."""

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
        if os.environ.get("SOURCE_DIRTY") == "1":
            print(" M crates/js/modules/tools.ts")
    elif args[0] == "show":
        print("1704153600")
    elif args[0] == "ls-files":
        prefixes = args[args.index("--") + 1:]
        files = [p.relative_to(root).as_posix() for p in root.rglob("*")
                 if p.is_file() and "target" not in p.relative_to(root).parts
                 and not p.name.endswith(".ignored.ts")
                 and any(p.relative_to(root).as_posix() == prefix
                         or p.relative_to(root).as_posix().startswith(prefix + "/") for prefix in prefixes)]
        sys.stdout.buffer.write("\0".join(sorted(files)).encode() + b"\0")
    else:
        sys.exit("unexpected Git command")
else:
    changed = os.environ.get("CHANGE_AT_" + args[0].upper())
    if changed:
        path = root / changed
        path.write_text(path.read_text() + "\n# concurrent edit\n")
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
        for name in ("tools/package.py", "LICENSE.md", "Cargo.toml",
                     ".mise.toml", ".mise.cross.toml", "mise.lock", "mise.cross.lock"):
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, destination)
        for name in ("crates/js/modules", "crates/js/types", "crates/protocol/bindings"):
            shutil.copytree(ROOT / name, self.root / name)
        shutil.copy2(ROOT / "crates/js/tsconfig.json", self.root / "crates/js/tsconfig.json")
        shutil.copy2(ROOT / "crates/protocol/README.md", self.root / "crates/protocol/README.md")
        self.environment = dict(os.environ, PATH=str(self.commands) + os.pathsep + os.environ["PATH"])
        self.output = self.root / "target/packages"

    def build(self, environment, *args):
        return subprocess.run([sys.executable, str(self.root / "tools/package.py"),
                               "--target", "aarch64-apple-darwin", *args], env=environment,
                              text=True, capture_output=True, timeout=30)

    def test_changed_package_inputs_prevent_archive_publication(self):
        ignored = self.root / "crates/js/modules/local.ignored.ts"
        ignored.write_text("export const value = 1;\n")
        cases = [("metadata", "Cargo.toml"), ("build", "LICENSE.md"),
                 ("build", ".mise.cross.toml"), ("build", "crates/js/modules/local.ignored.ts")]
        for phase, name in cases:
            with self.subTest(phase=phase, path=name):
                environment = dict(self.environment, **{"CHANGE_AT_" + phase.upper(): name})
                result = self.build(environment)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("source changed during the build", result.stderr)
                self.assertEqual(list(self.output.glob("*.tar.gz")), [])
        ignored.unlink()
        (self.root / "tools/unrelated-test.py").write_text("# An unrelated test file.\n")
        result = self.build(dict(self.environment, CHANGE_AT_BUILD="tools/unrelated-test.py"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.output / "yuke-aarch64-macos.tar.gz").is_file())

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

    def test_tagged_builds_require_clean_source_and_a_matching_release_version(self):
        cases = [({}, ["--tag", "v9.9.9"], "the tag must be v plus"),
                 ({}, ["--tag", "v1.2.3", "--nightly"], "the tag must be v plus"),
                 ({"PACKAGE_VERSION": "1.2.3-dev"}, ["--tag", "v1.2.3-dev"], "without -dev"),
                 ({"SOURCE_DIRTY": "1"}, ["--tag", "v1.2.3"], "require a clean working tree")]
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

    def test_concurrent_builds_publish_complete_archives_without_sidecars(self):
        targets = [("aarch64-apple-darwin", "yuke-aarch64-macos.tar.gz"),
                   ("x86_64-apple-darwin", "yuke-x86_64-macos.tar.gz")]
        processes = []
        try:
            for target, _ in targets:
                processes.append(subprocess.Popen(
                    [sys.executable, str(self.root / "tools/package.py"), "--target", target],
                    env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                ))
            for process in processes:
                stdout, stderr = process.communicate(timeout=30)
                self.assertEqual(process.returncode, 0, stdout + stderr)
            self.assertEqual(sorted(path.name for path in self.output.iterdir()),
                             ["yuke-aarch64-macos.tar.gz", "yuke-x86_64-macos.tar.gz"])
            for target, name in targets:
                with self.subTest(target=target), tarfile.open(self.output / name) as archive:
                    self.assertNotIn("lib/yuke/FILES.sha256", archive.getnames())
                    self.assertNotIn("lib/yuke/README.md", archive.getnames())
                    self.assertEqual(json.load(archive.extractfile("lib/yuke/build.json")), {
                        "format": 1, "version": "1.2.3", "commit": "1234567890abcdef1234567890abcdef12345678",
                        "target": target, "dirty": False,
                    })
                    self.assertEqual(archive.extractfile("bin/yuke").read(),
                                     b"#!/bin/sh\nprintf 'yuke 1.2.3\\n'\n")
                    self.assertEqual(archive.extractfile("lib/yuke/modules/tools.ts").read(),
                                     (self.root / "crates/js/modules/tools.ts").read_bytes())
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                process.communicate()


if __name__ == "__main__":
    unittest.main(verbosity=2)
