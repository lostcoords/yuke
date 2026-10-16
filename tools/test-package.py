#!/usr/bin/env python3
"""Test a real package and installer with isolated state. Pass an archive path."""

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
INSTALLER = ROOT / "tools/install.sh"
if len(sys.argv) != 2:
    sys.exit("usage: mise exec -- python3 tools/test-package.py ARCHIVE.tar.gz")
ARCHIVE = Path(sys.argv.pop()).resolve()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class PackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="yuke-package-tests-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.extracted = Path(cls.temporary.name) / "extracted"
        cls.extracted.mkdir()
        with tarfile.open(ARCHIVE) as archive:
            for member in archive.getmembers():
                if member.name.startswith("/") or ".." in Path(member.name).parts or not (member.isfile() or member.isdir()):
                    raise ValueError("the test package contains an unsafe archive entry")
            archive.extractall(cls.extracted)
        cls.identity = json.loads((cls.extracted / "lib/yuke/build.json").read_text())
        cls.expected_commit = os.environ.get("YUKE_PACKAGE_COMMIT")
        if cls.expected_commit is None:
            cls.expected_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        cls.compiler = shutil.which("tsc")
        if cls.compiler is None:
            raise RuntimeError("run these tests through mise; tsc is required")

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="case-", dir=self.temporary.name)
        self.addCleanup(self.directory.cleanup)
        self.scratch = Path(self.directory.name)
        self.home = self.scratch / "home with spaces"
        self.home.mkdir()
        self.environment = {
            key: value for key, value in os.environ.items()
            if key not in {"YUKE_APPNAME", "YUKE_CHANNEL", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"}
        }
        self.environment["HOME"] = str(self.home)
        self.environment["XDG_CONFIG_HOME"] = str(self.home / ".config")
        self.environment["XDG_DATA_HOME"] = str(self.home / ".local/share")
        self.environment["XDG_CACHE_HOME"] = str(self.home / ".cache")
        self.profile = self.home / ".config/yuke-rs"
        self.binary = self.home / ".local/bin/yuke"
        self.library = self.home / ".local/lib/yuke"

    def install(self, package=ARCHIVE, expected=0, piped=False):
        command = ["bash"] if piped else ["bash", str(INSTALLER), str(package)]
        result = subprocess.run(command, input=INSTALLER.read_text() if piped else None,
                                text=True, capture_output=True, env=self.environment,
                                cwd=self.scratch, timeout=60)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def snapshot(self):
        return {path.relative_to(self.home).as_posix(): digest(path)
                for path in (self.home / ".local").rglob("*") if path.is_file()}

    def mutation(self, change):
        package = self.scratch / "modified-package"
        shutil.copytree(self.extracted, package)
        change(package)
        archive = self.scratch / ARCHIVE.name
        with tarfile.open(archive, "w:gz") as result:
            result.add(package / "bin", arcname="bin")
            result.add(package / "lib", arcname="lib")
        return archive

    def seed_installation(self):
        self.binary.parent.mkdir(parents=True)
        self.binary.write_text("#!/bin/sh\nprintf 'yuke previous-version\\n'\n")
        self.binary.chmod(0o755)
        self.library.mkdir(parents=True)
        (self.library / "old-file").write_text("keep the working installation on failure\n")
        return self.snapshot()

    def add_executable(self, name, source):
        folder = self.scratch / "commands"
        folder.mkdir(exist_ok=True)
        command = folder / name
        command.write_text("#!/usr/bin/env python3\n" + source)
        command.chmod(0o755)
        self.environment["PATH"] = str(folder) + os.pathsep + self.environment["PATH"]

    def network(self, missing_stable=False, corrupt=False):
        self.environment["PACKAGE_FIXTURE"] = str(ARCHIVE)
        self.environment["PACKAGE_VERSION"] = self.identity["version"]
        self.environment["MISSING_STABLE"] = "1" if missing_stable else "0"
        self.environment["CORRUPT_DOWNLOAD"] = "1" if corrupt else "0"
        self.add_executable("curl", '''import os
from pathlib import Path
import shutil
import sys
args = sys.argv[1:]
url = args[-1]
base = "https://github.com/lostcoords/yuke/releases/"
channel = os.environ.get("YUKE_CHANNEL", "stable")
tag = "nightly" if channel == "nightly" else "v" + os.environ["PACKAGE_VERSION"]
package = Path(os.environ["PACKAGE_FIXTURE"])
if url == base + ("tag/nightly" if channel == "nightly" else "latest"):
    suffix = "" if os.environ["MISSING_STABLE"] == "1" else "tag/" + tag
    print("200 " + base + suffix, end="")
else:
    destination = Path(args[args.index("-o") + 1])
    if url == base + "download/" + tag + "/" + package.name:
        shutil.copyfile(package, destination)
        if os.environ["CORRUPT_DOWNLOAD"] == "1":
            destination.write_bytes(b"corrupt download")
    else:
        sys.exit("unexpected download URL: " + url)
''')

    def test_archive_installs_the_binary_library_and_editor_configuration(self):
        self.install()
        result = subprocess.check_output([str(self.binary), "--version"], text=True, env=self.environment)
        self.assertEqual(result, "yuke " + self.identity["version"] + "\n")
        self.assertEqual(json.loads((self.library / "build.json").read_text()), self.identity)
        self.assertFalse((self.library / "README.md").exists())
        self.assertEqual((self.profile / "yuke-library").resolve(), self.library.resolve())
        self.assertFalse((self.home / ".local/share").exists())
        self.assertFalse((self.home / ".agents").exists())

    def test_local_directory_is_rejected_without_replacing_the_working_installation(self):
        before = self.seed_installation()
        result = self.install(self.extracted, expected=1)
        self.assertIn("the local package must be an archive file", result)
        self.assertEqual(self.snapshot(), before)

    def test_package_source_and_protocol_bindings_match_the_checkout(self):
        self.assertEqual(self.identity["commit"], self.expected_commit)
        for source, installed in [(ROOT / "crates/js/modules", "modules"),
                                  (ROOT / "crates/js/types", "types"),
                                  (ROOT / "crates/protocol/bindings", "protocol/bindings")]:
            expected = {path.relative_to(source).as_posix(): path.read_bytes()
                        for path in source.rglob("*.ts") if path.is_file()}
            folder = self.extracted / "lib/yuke" / installed
            actual = {path.relative_to(folder).as_posix(): path.read_bytes()
                      for path in folder.rglob("*") if path.is_file()}
            self.assertEqual(actual, expected)
        self.assertEqual((self.extracted / "lib/yuke/protocol/README.md").read_bytes(),
                         (ROOT / "crates/protocol/README.md").read_bytes())

    def test_all_installed_modules_and_protocol_bindings_type_check(self):
        self.install()
        configuration = self.library / "tsconfig.json"
        result = subprocess.run([self.compiler, "-p", str(configuration), "--pretty", "false"],
                                text=True, capture_output=True, cwd=self.scratch, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for folder in ("modules/internal", "protocol/bindings"):
            with self.subTest(folder=folder):
                invalid = self.library / folder / "package-type-error.ts"
                invalid.write_text('export const value: string = 1;\n')
                rejected = subprocess.run([self.compiler, "-p", str(configuration), "--pretty", "false"],
                                          text=True, capture_output=True, cwd=self.scratch, timeout=30)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("TS2322", rejected.stdout + rejected.stderr)
                invalid.unlink()

    def test_installed_rpc_initializes_without_provider_credentials(self):
        self.install()
        request = {"jsonrpc": "2.0", "id": 7, "method": "initialize", "params": {
            "protocolVersion": 1, "clientInfo": {"name": "package-test", "version": "1"}}}
        result = subprocess.run([str(self.binary), "--rpc"], input=json.dumps(request) + "\n",
                                text=True, capture_output=True, env=self.environment,
                                cwd=self.scratch, timeout=15, check=True)
        self.assertEqual(json.loads(result.stdout), {"jsonrpc": "2.0", "id": 7, "result": {
            "protocolVersion": 1, "agentInfo": {"name": "yuke", "version": self.identity["version"]}}})

    def test_editor_checks_consumer_source_and_protocol_types_through_the_profile_link(self):
        self.install()
        consumer = self.profile / "consumer.ts"
        consumer.write_text('''import type { Tool } from "yuke:tools";
import type { ClientRequest } from "yuke:protocol/ClientRequest";
import type { Response } from "yuke:protocol/Response";
const tool: Tool = {
  name: "example", description: "An editor example", parameters: { type: "object", properties: {} },
  concurrency: "serial", execute: () => new Promise<string>((resolve) => setTimeout(() => resolve("done"), 1)),
};
void tool;
const request: ClientRequest = { method: "initialize", params: {
  protocolVersion: 1, clientInfo: { name: "consumer", version: "1" },
} };
void request;
declare const response: Response;
if ("result" in response) {
  // @ts-expect-error A protocol result stays unknown until the consumer validates it.
  const text: string = response.result;
  void text;
}
''')
        command = [self.compiler, "-p", str(self.profile), "--pretty", "false"]
        checked = subprocess.run(command, text=True, capture_output=True, cwd=self.scratch, timeout=30)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        consumer.write_text(consumer.read_text().replace('concurrency: "serial"', 'concurrency: "invalid"'))
        rejected = subprocess.run(command, text=True, capture_output=True, cwd=self.scratch, timeout=30)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn('Type \'"invalid"\' is not assignable', rejected.stdout + rejected.stderr)

    def test_upgrade_preserves_user_configuration_skills_and_shell_files(self):
        self.seed_installation()
        files = {
            ".config/yuke-rs/config.json": '{"model":"user/model"}\n',
            ".config/yuke-rs/tsconfig.json": '{"compilerOptions":{"strict":true}}\n',
            ".agents/skills/unrelated/SKILL.md": "user skill\n",
            ".bashrc": "user shell settings\n",
        }
        for name, text in files.items():
            path = self.home / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        result = self.install()
        self.assertIn("Replacing ", result)
        self.assertEqual(digest(self.binary), digest(self.extracted / "bin/yuke"))
        self.assertFalse((self.library / "old-file").exists())
        for name, text in files.items():
            self.assertEqual((self.home / name).read_text(), text)

    def test_upgrade_removes_only_the_obsolete_installer_owned_skill_link(self):
        skill = self.home / ".agents/skills/yuke"
        skill.parent.mkdir(parents=True)
        skill.symlink_to(self.library / "skills/yuke")
        self.install()
        self.assertFalse(skill.is_symlink())
        custom = self.home / "my-skill"
        custom.mkdir()
        (custom / "SKILL.md").write_text("user-owned skill\n")
        skill.symlink_to(custom)
        self.install()
        self.assertEqual(skill.resolve(), custom.resolve())
        self.assertEqual((skill / "SKILL.md").read_text(), "user-owned skill\n")

    def test_same_version_reinstallation_repairs_missing_library_files(self):
        self.install()
        original = (self.library / "modules/internal/signal.ts").read_bytes()
        (self.library / "modules/internal/signal.ts").unlink()
        self.install()
        self.assertEqual((self.library / "modules/internal/signal.ts").read_bytes(), original)
        self.assertEqual(json.loads((self.library / "build.json").read_text()), self.identity)

    def test_archive_symlinks_are_rejected_before_extraction(self):
        before = self.seed_installation()
        def link(package):
            path = package / "lib/yuke/modules/tools.ts"
            path.unlink()
            path.symlink_to("builtins.ts")
        result = self.install(self.mutation(link), expected=1)
        self.assertIn("archive contains a link or special file", result)
        self.assertEqual(self.snapshot(), before)

    def test_unsafe_archive_paths_and_hardlinks_are_rejected_before_extraction(self):
        before = self.seed_installation()
        for name, kind, message in [
            ("lib/yuke/../../../escape", tarfile.REGTYPE, "package contains an unsafe path"),
            ("lib/yuke/hardlink", tarfile.LNKTYPE, "archive contains a link or special file"),
        ]:
            with self.subTest(name=name):
                archive = self.scratch / ARCHIVE.name
                with tarfile.open(archive, "w:gz") as result:
                    result.add(self.extracted / "bin", arcname="bin")
                    result.add(self.extracted / "lib", arcname="lib")
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    if kind == tarfile.LNKTYPE:
                        member.linkname = "lib/yuke/modules/tools.ts"
                    result.addfile(member)
                result = self.install(archive, expected=1)
                self.assertIn(message, result)
                self.assertEqual(self.snapshot(), before)

    def test_unusable_binary_is_rejected_before_the_working_installation_changes(self):
        before = self.seed_installation()
        def damage(package):
            (package / "bin/yuke").write_text("#!/bin/sh\nexit 37\n")
        result = self.install(self.mutation(damage), expected=1)
        self.assertIn("staged binary does not run", result)
        self.assertEqual(self.snapshot(), before)

    def test_binary_with_wrong_build_identity_preserves_the_working_installation(self):
        before = self.seed_installation()
        def damage(package):
            (package / "bin/yuke").write_text("#!/bin/sh\nprintf 'yuke wrong-version\\n'\n")
        result = self.install(self.mutation(damage), expected=1)
        self.assertIn("wrong version", result)
        self.assertEqual(self.snapshot(), before)

    def test_wrong_package_target_preserves_the_working_installation(self):
        before = self.seed_installation()
        def wrong_target(package):
            metadata = package / "lib/yuke/build.json"
            identity = json.loads(metadata.read_text())
            identity["target"] = "unsupported-package-target"
            metadata.write_text(json.dumps(identity, indent=2) + "\n")
        result = self.install(self.mutation(wrong_target), expected=1)
        self.assertIn("package target does not match", result)
        self.assertEqual(self.snapshot(), before)

    def test_unknown_package_format_preserves_the_working_installation(self):
        before = self.seed_installation()
        def wrong_format(package):
            metadata = package / "lib/yuke/build.json"
            identity = json.loads(metadata.read_text())
            identity["format"] = 2
            metadata.write_text(json.dumps(identity, indent=2) + "\n")
        result = self.install(self.mutation(wrong_format), expected=1)
        self.assertIn("unsupported package format", result)
        self.assertEqual(self.snapshot(), before)

    def test_missing_required_files_preserve_the_working_installation(self):
        before = self.seed_installation()
        for name in ("bin/yuke", "lib/yuke/modules/tools.ts", "lib/yuke/types/globals.d.ts",
                     "lib/yuke/protocol/bindings/ClientRequest.ts", "lib/yuke/build.json"):
            with self.subTest(path=name):
                modified = self.scratch / "modified-package"
                if modified.exists():
                    shutil.rmtree(modified)
                archive = self.mutation(lambda package: (package / name).unlink())
                result = self.install(archive, expected=1)
                self.assertIn("the package has no regular " + name, result)
                self.assertEqual(self.snapshot(), before)

    def test_cleanup_failure_retains_evidence_after_library_restoration(self):
        self.seed_installation()
        original_binary = self.binary.read_bytes()
        self.environment["REAL_MV"] = shutil.which("mv")
        self.add_executable("mv", '''import os
import sys
if any(argument.endswith("/package/bin/yuke") for argument in sys.argv[1:]):
    sys.exit(33)
os.execv(os.environ["REAL_MV"], ["mv"] + sys.argv[1:])
''')
        self.environment["REAL_RM"] = shutil.which("rm")
        self.environment["INSTALLED_LIBRARY"] = str(self.library)
        self.add_executable("rm", '''import os
import sys
if any("/.yuke-install." in argument or argument == os.environ["INSTALLED_LIBRARY"] for argument in sys.argv[1:]):
    sys.exit(55)
os.execv(os.environ["REAL_RM"], ["rm"] + sys.argv[1:])
''')
        result = self.install(expected=33)
        self.assertEqual(self.binary.read_bytes(), original_binary)
        self.assertEqual((self.library / "old-file").read_text(), "keep the working installation on failure\n")
        self.assertFalse((self.home / ".local/.yuke-install.lock").exists())
        retained = list((self.home / ".local").glob(".yuke-install.*"))
        self.assertEqual(len(retained), 1)
        self.assertIn("could not remove", result)
        self.assertEqual((retained[0] / "failed-library/build.json").read_bytes(),
                         (self.extracted / "lib/yuke/build.json").read_bytes())

    def test_failed_binary_replacement_restores_the_previous_library(self):
        before = self.seed_installation()
        self.environment["REAL_MV"] = shutil.which("mv")
        self.add_executable("mv", '''import os
import sys
if any(argument.endswith("/package/bin/yuke") for argument in sys.argv[1:]):
    sys.exit(33)
os.execv(os.environ["REAL_MV"], ["mv"] + sys.argv[1:])
''')
        self.install(expected=33)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.home / ".local/.yuke-install.lock").exists())

    def test_stable_and_nightly_downloads_install_real_packages_from_one_release(self):
        self.network()
        self.install(piped=True)
        self.assertEqual(digest(self.binary), digest(self.extracted / "bin/yuke"))
        (self.library / "modules/tools.ts").unlink()
        self.environment["YUKE_CHANNEL"] = "nightly"
        self.install(piped=True)
        self.assertEqual((self.library / "modules/tools.ts").read_bytes(),
                         (self.extracted / "lib/yuke/modules/tools.ts").read_bytes())

    def test_corrupt_download_is_rejected_before_extraction_or_replacement(self):
        before = self.seed_installation()
        self.network(corrupt=True)
        result = self.install(expected=1, piped=True)
        self.assertIn("cannot read the package archive", result)
        self.assertEqual(self.snapshot(), before)

    def test_repository_without_a_stable_release_does_not_replace_an_installation(self):
        before = self.seed_installation()
        self.network(missing_stable=True)
        result = self.install(expected=1, piped=True)
        self.assertIn("has no stable release", result)
        self.assertEqual(self.snapshot(), before)

    def test_symlinked_profile_preserves_user_configuration(self):
        shared = self.scratch / "shared-profile"
        shared.mkdir()
        configuration = shared / "tsconfig.json"
        configuration.write_text('{"compilerOptions":{"strict":true}}\n')
        self.profile.parent.mkdir(parents=True)
        self.profile.symlink_to(shared, target_is_directory=True)
        self.install()
        self.assertEqual(configuration.read_text(), '{"compilerOptions":{"strict":true}}\n')
        self.assertEqual((shared / "yuke-library").resolve(), self.library.resolve())
        self.assertEqual(self.profile.resolve(), shared.resolve())

    def test_existing_editor_link_and_dangling_user_configuration_stay_unchanged(self):
        self.profile.mkdir(parents=True)
        (self.profile / "yuke-library").mkdir()
        (self.profile / "yuke-library/user-file").write_text("keep me\n")
        (self.profile / "tsconfig.json").symlink_to("missing-user-configuration.json")
        self.install()
        self.assertEqual((self.profile / "yuke-library/user-file").read_text(), "keep me\n")
        self.assertEqual(os.readlink(self.profile / "tsconfig.json"), "missing-user-configuration.json")
        self.assertEqual(digest(self.binary), digest(self.extracted / "bin/yuke"))

    def test_binary_matches_its_native_platform(self):
        expected = "aarch64" if platform.machine() in {"aarch64", "arm64"} else "x86_64"
        binary = str(self.extracted / "bin/yuke")
        if platform.system() == "Darwin":
            self.assertEqual(self.identity["target"], expected + "-apple-darwin")
            architecture = "arm64" if expected == "aarch64" else "x86_64"
            self.assertEqual(subprocess.check_output(["lipo", "-archs", binary], text=True).split(), [architecture])
        else:
            self.assertEqual(self.identity["target"], expected + "-unknown-linux-musl")
            environment = dict(os.environ, LC_ALL="C")
            header = subprocess.check_output(["readelf", "-h", binary], text=True, env=environment)
            machine = next(line.split(":", 1)[1].strip() for line in header.splitlines()
                           if line.strip().startswith("Machine:"))
            self.assertEqual(machine, "AArch64" if expected == "aarch64" else "Advanced Micro Devices X86-64")
            headers = subprocess.check_output(["readelf", "-l", binary], text=True, env=environment)
            dynamic = subprocess.check_output(["readelf", "-d", binary], text=True, env=environment)
            self.assertNotIn("INTERP", headers)
            self.assertNotIn("(NEEDED)", dynamic)
        self.assertEqual(subprocess.check_output([binary, "--version"], text=True),
                         "yuke " + self.identity["version"] + "\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
