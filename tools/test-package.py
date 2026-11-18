#!/usr/bin/env python3
"""Test a real package and installer with isolated state. Pass an archive path."""

import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import uuid


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
        self.profile = self.home / ".config/yuke"
        self.binary = self.home / ".local/bin/yuke"
        self.library = self.home / ".local/lib/yuke"
        self.skill = self.home / ".agents/skills/yuke"

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

    def network(self, corrupt=False):
        self.environment["PACKAGE_FIXTURE"] = str(ARCHIVE)
        self.environment["CORRUPT_DOWNLOAD"] = "1" if corrupt else "0"
        self.add_executable("curl", '''import os
from pathlib import Path
import shutil
import sys
args = sys.argv[1:]
url = args[-1]
package = Path(os.environ["PACKAGE_FIXTURE"])
folder = "download/nightly/" if os.environ.get("YUKE_CHANNEL") == "nightly" else "latest/download/"
if url != "https://github.com/lostcoords/yuke/releases/" + folder + package.name:
    sys.exit("unexpected download URL: " + url)
destination = Path(args[args.index("-o") + 1])
shutil.copyfile(package, destination)
if os.environ["CORRUPT_DOWNLOAD"] == "1":
    destination.write_bytes(b"corrupt download")
''')

    def test_archive_installs_the_binary_library_and_editor_configuration(self):
        self.install()
        result = subprocess.check_output([str(self.binary), "--version"], text=True, env=self.environment)
        self.assertEqual(result, "yuke " + self.identity["version"] + "\n")
        self.assertEqual(json.loads((self.library / "build.json").read_text()), self.identity)
        self.assertFalse((self.library / "README.md").exists())
        configuration = json.loads((self.profile / "tsconfig.json").read_text())
        self.assertEqual(configuration["extends"], str(self.library / "tsconfig.json"))
        self.assertFalse((self.profile / "yuke-library").exists())
        self.assertFalse((self.home / ".local/share").exists())
        self.assertEqual(os.readlink(self.skill), str(self.library / "skills/yuke"))
        self.assertEqual((self.skill / "SKILL.md").read_bytes(), (ROOT / "skills/yuke/SKILL.md").read_bytes())

    def test_package_files_match_the_checkout(self):
        self.assertEqual(self.identity["commit"], self.expected_commit)
        for source, installed, pattern in [(ROOT / "crates/js/modules", "modules", "*.ts"),
                                           (ROOT / "crates/js/types", "types", "*.d.ts"),
                                           (ROOT / "crates/protocol/bindings", "protocol/bindings", "**/*.ts")]:
            expected = {path.relative_to(source).as_posix(): path.read_bytes()
                        for path in source.glob(pattern) if path.is_file() and path.name != "native.d.ts"}
            folder = self.extracted / "lib/yuke" / installed
            actual = {path.relative_to(folder).as_posix(): path.read_bytes()
                      for path in folder.rglob("*") if path.is_file()}
            self.assertEqual(actual, expected)
        self.assertEqual((self.extracted / "lib/yuke/protocol/README.md").read_bytes(),
                         (ROOT / "crates/protocol/README.md").read_bytes())
        for source, installed in [(ROOT / "docs", "docs"), (ROOT / "skills/yuke", "skills/yuke")]:
            expected = {path.relative_to(source).as_posix(): path.read_bytes()
                        for path in source.rglob("*") if path.is_file()
                        and not {"tests", "tsconfig.json"} & set(path.relative_to(source).parts)}
            folder = self.extracted / "lib/yuke" / installed
            actual = {path.relative_to(folder).as_posix(): path.read_bytes()
                      for path in folder.rglob("*") if path.is_file()}
            self.assertEqual(actual, expected)

    def test_each_library_file_that_the_skill_names_is_in_the_package(self):
        library = self.extracted / "lib/yuke"
        text = (library / "skills/yuke/SKILL.md").read_text()
        names = re.findall(r"`([^`\s]+)`", text)
        names = [name for name in names
                 if name.startswith(("docs/", "modules/", "types/", "protocol/")) and name.endswith((".md", ".ts"))]
        self.assertIn("docs/guide/index.md", names)
        for name in names:
            with self.subTest(name=name):
                self.assertTrue(list(library.glob(name)), name + " is not in the package")

    def test_all_installed_modules_and_protocol_bindings_type_check(self):
        self.install()
        configuration = self.library / "tsconfig.json"
        result = subprocess.run([self.compiler, "-p", str(configuration), "--pretty", "false"],
                                text=True, capture_output=True, cwd=self.scratch, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for folder in ("modules", "protocol/bindings"):
            with self.subTest(folder=folder):
                invalid = self.library / folder / "package-type-error.ts"
                invalid.write_text('export const value: string = 1;\n')
                rejected = subprocess.run([self.compiler, "-p", str(configuration), "--pretty", "false"],
                                          text=True, capture_output=True, cwd=self.scratch, timeout=30)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("TS2322", rejected.stdout + rejected.stderr)
                invalid.unlink()

    def test_an_author_import_of_an_internal_module_fails_the_type_check(self):
        self.install()
        plugin = self.profile / "plugins/internal-import"
        plugin.mkdir(parents=True)
        (plugin / "index.ts").write_text('import { defineTool } from "yuke:internal/define";\nexport { defineTool };\n')
        configuration = self.profile / "tsconfig.json"
        result = subprocess.run([self.compiler, "-p", str(configuration), "--pretty", "false"],
                                text=True, capture_output=True, cwd=self.scratch, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TS2307", result.stdout + result.stderr)
        (plugin / "index.ts").write_text('import type { PluginApply, PluginSession } from "yuke:plugins";\n'
                                         'import { readTextFile } from "yuke:fs";\n'
                                         'export const apply: PluginApply = async (ctx) => {\n'
                                         '  await readTextFile("state.json", { cwd: ctx.dataDir, signal: ctx.signal });\n'
                                         '};\n'
                                         'export const session: PluginSession = (s) => () => s.notify("info", s.cwd);\n')
        accepted = subprocess.run([self.compiler, "-p", str(configuration), "--pretty", "false"],
                                  text=True, capture_output=True, cwd=self.scratch, timeout=30)
        self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)

    def test_installed_rpc_initializes_without_provider_credentials(self):
        self.install()
        request = {"jsonrpc": "2.0", "id": 7, "method": "initialize", "params": {
            "protocolVersion": 1, "clientInfo": {"name": "package-test", "version": "1"}}}
        result = subprocess.run([str(self.binary), "--rpc"], input=json.dumps(request) + "\n",
                                text=True, capture_output=True, env=self.environment,
                                cwd=self.scratch, timeout=15, check=True)
        response = json.loads(result.stdout)
        instance_id = response["result"].pop("instanceId")
        self.assertEqual(str(uuid.UUID(instance_id)), instance_id)
        self.assertEqual(response, {"jsonrpc": "2.0", "id": 7, "result": {
            "protocolVersion": 1, "agentInfo": {"name": "yuke", "version": self.identity["version"]}}})

    def test_editor_checks_consumer_source_and_protocol_types_through_the_profile_configuration(self):
        self.install()
        consumer = self.profile / "consumer.ts"
        consumer.write_text('''import type { Tool } from "yuke:tools";
import type { ClientRequest } from "yuke:protocol/ClientRequest";
import type { Response } from "yuke:protocol/Response";
const tool: Tool = {
  name: "example", description: "An editor example", inputSchema: { type: "object", properties: {} },
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
            ".config/yuke/config.json": '{"model":"user/model"}\n',
            ".config/yuke/tsconfig.json": '{"compilerOptions":{"strict":true}}\n',
            ".agents/skills/unrelated/SKILL.md": "user skill\n",
            ".bashrc": "user shell settings\n",
        }
        for name, text in files.items():
            path = self.home / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.install()
        self.assertEqual(digest(self.binary), digest(self.extracted / "bin/yuke"))
        self.assertFalse((self.library / "old-file").exists())
        for name, text in files.items():
            self.assertEqual((self.home / name).read_text(), text)

    def test_same_version_reinstallation_repairs_missing_library_files(self):
        self.install()
        original = (self.library / "modules/plugins.ts").read_bytes()
        (self.library / "modules/plugins.ts").unlink()
        self.install()
        self.assertEqual((self.library / "modules/plugins.ts").read_bytes(), original)
        self.assertEqual(json.loads((self.library / "build.json").read_text()), self.identity)

    def test_unusable_binary_is_rejected_before_the_working_installation_changes(self):
        before = self.seed_installation()
        def damage(package):
            (package / "bin/yuke").write_text("#!/bin/sh\nexit 37\n")
        result = self.install(self.mutation(damage), expected=1)
        self.assertIn("the new yuke binary does not run", result)
        self.assertEqual(self.snapshot(), before)

    def test_stable_and_nightly_downloads_install_real_packages_from_one_release(self):
        self.network()
        self.install(piped=True)
        self.assertEqual(digest(self.binary), digest(self.extracted / "bin/yuke"))
        (self.library / "modules/tools.ts").unlink()
        self.environment["YUKE_CHANNEL"] = "nightly"
        self.install(piped=True)
        self.assertEqual((self.library / "modules/tools.ts").read_bytes(),
                         (self.extracted / "lib/yuke/modules/tools.ts").read_bytes())

    def test_corrupt_download_keeps_the_working_installation(self):
        before = self.seed_installation()
        self.network(corrupt=True)
        self.install(expected=1, piped=True)
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
        self.assertEqual(self.profile.resolve(), shared.resolve())

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
