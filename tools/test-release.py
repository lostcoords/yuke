#!/usr/bin/env python3
"""Test release publication against an isolated HTTP server."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, unquote, urlsplit


ROOT = Path(__file__).resolve().parent.parent
COMMIT = "1" * 40
PREVIOUS = "2" * 40
REPOSITORY = "example/yuke"
PLATFORMS = {
    "yuke-aarch64-linux-musl.tar.gz": "aarch64-unknown-linux-musl",
    "yuke-aarch64-macos.tar.gz": "aarch64-apple-darwin",
    "yuke-x86_64-linux-musl.tar.gz": "x86_64-unknown-linux-musl",
    "yuke-x86_64-macos.tar.gz": "x86_64-apple-darwin",
}


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="yuke-release-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.packages = self.root / "dist"
        self.packages.mkdir()
        self.references = {"heads/main": COMMIT, "tags/v1.2.3": COMMIT}
        self.annotated = {}
        self.release = None
        self.uploaded = {}
        self.assets = []
        self.other_releases = []
        self.requests = []
        self.fail_upload = None
        self.move_on_upload = None
        self.fail_release_read = False
        self.fail_publish = False
        self.ignore_publish = False
        self.advance_on_publish = False
        self.restrict_workflow_target = False
        self.ci = [{"head_sha": COMMIT, "head_branch": "main", "event": "push", "conclusion": "success",
                    "head_repository": {"full_name": REPOSITORY}}]
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def handle_request(self):
                parsed = urlsplit(self.path)
                path = unquote(parsed.path.removeprefix("/repos/" + REPOSITORY + "/"))
                query = parse_qs(parsed.query)
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                data = body if parsed.path.startswith("/uploads/") else json.loads(body) if body else None
                fixture.requests.append((self.command, path, data))
                status, response = 200, None
                if self.headers.get("Authorization") != "Bearer fixture-token":
                    status = 401
                elif self.command == "GET" and path.startswith("git/ref/"):
                    reference = path.removeprefix("git/ref/")
                    value = fixture.references.get(reference)
                    if value is None:
                        status = 404
                    else:
                        response = {"object": {"type": "tag" if value in fixture.annotated else "commit", "sha": value}}
                elif self.command == "GET" and path.startswith("git/tags/"):
                    response = {"object": fixture.annotated[path.removeprefix("git/tags/")]}
                elif self.command == "GET" and path == "actions/workflows/ci.yml/runs":
                    if query == {"branch": ["main"], "event": ["push"], "status": ["success"],
                                 "head_sha": [COMMIT], "per_page": ["1"]}:
                        response = {"workflow_runs": fixture.ci}
                    else:
                        status = 400
                elif self.command == "GET" and path.startswith("releases/tags/"):
                    if fixture.release is None or fixture.release["draft"]:
                        status = 404
                    else:
                        response = fixture.release
                elif self.command == "GET" and path == "releases":
                    if fixture.fail_release_read:
                        status = 403
                    else:
                        releases = fixture.other_releases + ([] if fixture.release is None else [fixture.release])
                        page = int(query["page"][0])
                        response = releases[(page - 1) * 100:page * 100]
                elif self.command == "GET" and path == "releases/41/assets":
                    page = int(query["page"][0])
                    response = fixture.assets[(page - 1) * 100:page * 100]
                elif self.command == "POST" and path == "releases":
                    if fixture.release is not None:
                        status = 422
                    elif fixture.restrict_workflow_target and "target_commitish" in data:
                        status = 403
                    else:
                        fixture.release = dict({"target_commitish": "main"}, **data, id=41,
                                               upload_url=fixture.base + "/uploads/41{?name,label}")
                        response = fixture.release
                        status = 201
                elif self.command == "PATCH" and path == "releases/41":
                    if fixture.fail_publish and data.get("draft") is False:
                        status = 503
                    else:
                        if fixture.advance_on_publish and data.get("draft") is False:
                            fixture.references["heads/main"] = "3" * 40
                        if not fixture.ignore_publish or data.get("draft") is not False:
                            fixture.release.update(data)
                        response = fixture.release
                elif self.command == "DELETE" and path.startswith("releases/assets/"):
                    identifier = int(path.rsplit("/", 1)[1])
                    fixture.assets = [asset for asset in fixture.assets if asset["id"] != identifier]
                    status = 204
                elif self.command == "POST" and parsed.path == "/uploads/41":
                    name = query["name"][0]
                    fixture.uploaded[name] = body
                    fixture.assets.append({"id": len(fixture.assets) + 1, "name": name, "size": len(body),
                                           "state": "starter" if fixture.fail_upload == name else "uploaded"})
                    if fixture.move_on_upload is not None:
                        fixture.references[fixture.move_on_upload] = PREVIOUS
                    if fixture.fail_upload == name:
                        status = 502
                    else:
                        status, response = 201, fixture.assets[-1]
                elif self.command == "POST" and path == "git/refs":
                    fixture.references[data["ref"].removeprefix("refs/")] = data["sha"]
                    status, response = 201, {"object": {"type": "commit", "sha": data["sha"]}}
                elif self.command == "PATCH" and path == "git/refs/tags/nightly":
                    fixture.references["tags/nightly"] = data["sha"]
                    response = {"object": {"type": "commit", "sha": data["sha"]}}
                else:
                    status = 500
                encoded = json.dumps(response).encode() if status != 204 else b""
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            do_GET = handle_request
            do_POST = handle_request
            do_PATCH = handle_request
            do_DELETE = handle_request

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.base = "http://127.0.0.1:" + str(self.server.server_port)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.stop_server, thread)
        self.environment = dict(os.environ, GITHUB_REPOSITORY=REPOSITORY, GITHUB_API_URL=self.base,
                                GH_TOKEN="fixture-token", GITHUB_OUTPUT=str(self.root / "outputs"))
        self.write_packages()

    def stop_server(self, thread):
        self.server.shutdown()
        self.server.server_close()
        thread.join()

    def write_packages(self, version="1.2.3", change=None):
        for name, target in PLATFORMS.items():
            identity = {"format": 1, "version": version, "commit": COMMIT, "target": target, "dirty": False}
            if change is not None:
                identity.update(change)
            body = json.dumps(identity).encode()
            with tarfile.open(self.packages / name, "w:gz") as archive:
                member = tarfile.TarInfo("lib/yuke/build.json")
                member.size = len(body)
                archive.addfile(member, io.BytesIO(body))

    def run_release(self, tag="v1.2.3", command="publish", expected=0):
        result = subprocess.run([sys.executable, str(ROOT / "tools/release.py"), command,
                                 "--commit", COMMIT, "--tag", tag, "--directory", str(self.packages)],
                                env=self.environment, text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def published(self, tag, prerelease):
        self.assertEqual(self.release["tag_name"], tag)
        self.assertEqual(self.release["target_commitish"], COMMIT if tag == "nightly" else "main")
        self.assertFalse(self.release["draft"])
        self.assertEqual(self.release["prerelease"], prerelease)
        self.assertEqual(self.release["make_latest"], "false" if prerelease else "legacy")
        self.assertEqual({asset["name"] for asset in self.assets}, set(PLATFORMS))
        self.assertEqual(self.uploaded, {name: (self.packages / name).read_bytes() for name in PLATFORMS})
        publications = [index for index, (method, path, data) in enumerate(self.requests)
                        if method == "PATCH" and path == "releases/41" and data.get("draft") is False]
        uploads = [index for index, (method, path, _) in enumerate(self.requests)
                   if method == "POST" and path == "/uploads/41"]
        self.assertEqual(len(publications), 1)
        self.assertGreater(publications[0], max(uploads))

    def seed_release(self, tag="nightly", draft=False):
        self.release = {"id": 41, "tag_name": tag, "draft": draft, "prerelease": True,
                        "target_commitish": PREVIOUS, "upload_url": self.base + "/uploads/41{?name,label}"}
        self.assets = [{"id": 70, "name": "obsolete-asset", "size": 3, "state": "uploaded"}]
        self.references["tags/" + tag] = PREVIOUS

    def test_tagged_release_publishes_only_after_all_archives_arrive(self):
        self.run_release()
        self.published("v1.2.3", False)
        self.assertEqual(self.references["tags/v1.2.3"], COMMIT)

    def test_suffixed_tag_publishes_a_prerelease_without_changing_latest(self):
        self.write_packages("1.2.3-rc.1")
        self.references["tags/v1.2.3-rc.1"] = COMMIT
        self.run_release("v1.2.3-rc.1")
        self.published("v1.2.3-rc.1", True)

    def test_build_metadata_does_not_turn_a_version_into_a_prerelease(self):
        self.write_packages("1.2.3+build-dev.5")
        self.references["tags/v1.2.3+build-dev.5"] = COMMIT
        self.run_release("v1.2.3+build-dev.5")
        self.published("v1.2.3+build-dev.5", False)

    def test_an_existing_tag_needs_no_workflow_write_permission(self):
        self.references["heads/main"] = PREVIOUS
        self.restrict_workflow_target = True
        self.run_release()
        self.published("v1.2.3", False)
        self.assertEqual(self.references["tags/v1.2.3"], COMMIT)

    def test_annotated_tag_resolves_to_its_source_commit(self):
        self.references["tags/v1.2.3"] = "3" * 40
        self.annotated["3" * 40] = {"type": "tag", "sha": "4" * 40}
        self.annotated["4" * 40] = {"type": "commit", "sha": COMMIT}
        self.run_release()
        self.published("v1.2.3", False)

    def test_first_nightly_creates_its_tag_and_stays_a_prerelease(self):
        self.write_packages("1.2.3-nightly.20261016+111111111111")
        self.run_release("nightly")
        self.published("nightly", True)
        self.assertEqual(self.references["tags/nightly"], COMMIT)

    def test_nightly_replaces_all_previous_assets_and_moves_its_tag(self):
        self.seed_release()
        self.write_packages("1.2.3-nightly.20261016+111111111111")
        self.run_release("nightly")
        self.published("nightly", True)
        self.assertEqual(self.references["tags/nightly"], COMMIT)

    def test_a_failed_upload_leaves_a_draft_that_a_retry_can_complete(self):
        self.fail_upload = "yuke-x86_64-linux-musl.tar.gz"
        self.assertIn("HTTP 502", self.run_release(expected=1))
        self.assertTrue(self.release["draft"])
        self.fail_upload = None
        self.run_release()
        self.published("v1.2.3", False)

    def test_failed_nightly_upload_keeps_its_tag_and_can_resume_the_draft(self):
        self.seed_release()
        self.write_packages("1.2.3-nightly.20261016+111111111111")
        self.fail_upload = "yuke-x86_64-linux-musl.tar.gz"
        self.assertIn("HTTP 502", self.run_release("nightly", expected=1))
        self.assertTrue(self.release["draft"])
        self.assertEqual(self.references["tags/nightly"], PREVIOUS)
        self.fail_upload = None
        self.run_release("nightly")
        self.published("nightly", True)
        self.assertEqual(self.references["tags/nightly"], COMMIT)

    def test_failed_nightly_publication_can_resume_after_its_tag_moves(self):
        self.seed_release()
        self.write_packages("1.2.3-nightly.20261016+111111111111")
        self.fail_publish = True
        self.assertIn("HTTP 503", self.run_release("nightly", expected=1))
        self.assertTrue(self.release["draft"])
        self.assertEqual(self.references["tags/nightly"], COMMIT)
        self.fail_publish = False
        self.requests.clear()
        self.run_release("nightly")
        self.published("nightly", True)

    def test_a_draft_on_a_later_release_page_can_resume(self):
        self.seed_release("v1.2.3", draft=True)
        self.release["target_commitish"] = "main"
        self.references["tags/v1.2.3"] = COMMIT
        self.other_releases = [{"tag_name": "v0.0." + str(index), "id": index} for index in range(101)]
        self.run_release()
        self.published("v1.2.3", False)

    def test_an_orphaned_nightly_draft_can_publish_without_a_tag(self):
        self.seed_release(draft=True)
        del self.references["tags/nightly"]
        self.write_packages("1.2.3-nightly.20261016+111111111111")
        self.run_release("nightly")
        self.published("nightly", True)
        self.assertEqual(self.references["tags/nightly"], COMMIT)

    def test_a_published_tagged_release_is_not_hidden_or_overwritten(self):
        self.seed_release("v1.2.3")
        self.references["tags/v1.2.3"] = COMMIT
        self.assertIn("already published", self.run_release(expected=1))
        self.assertFalse(self.release["draft"])
        self.assertEqual(self.assets, [{"id": 70, "name": "obsolete-asset", "size": 3, "state": "uploaded"}])

    def test_a_tag_that_moves_during_upload_leaves_the_draft_unpublished(self):
        self.move_on_upload = "tags/v1.2.3"
        self.assertIn("tag moved", self.run_release(expected=1))
        self.assertTrue(self.release["draft"])
        self.assertEqual(set(self.uploaded), set(PLATFORMS))

    def test_a_stale_nightly_keeps_the_published_release_and_tag(self):
        self.seed_release()
        self.references["heads/main"] = PREVIOUS
        self.write_packages("1.2.3-nightly.20261016+111111111111")
        self.assertIn("skip this nightly", self.run_release("nightly"))
        self.assertFalse(self.release["draft"])
        self.assertEqual(self.references["tags/nightly"], PREVIOUS)
        self.assertEqual(self.assets[0]["name"], "obsolete-asset")

    def test_main_that_moves_during_upload_does_not_move_the_nightly_tag(self):
        self.seed_release()
        self.move_on_upload = "heads/main"
        self.write_packages("1.2.3-nightly.20261016+111111111111")
        self.assertIn("skip this nightly", self.run_release("nightly"))
        self.assertTrue(self.release["draft"])
        self.assertEqual(self.references["tags/nightly"], PREVIOUS)
        self.assertEqual(set(self.uploaded), set(PLATFORMS))

    def test_main_can_advance_at_publication_without_mixing_release_commits(self):
        self.seed_release()
        self.write_packages("1.2.3-nightly.20261016+111111111111")
        self.advance_on_publish = True
        self.run_release("nightly")
        self.published("nightly", True)
        self.assertEqual(self.references["tags/nightly"], COMMIT)
        self.assertEqual(self.references["heads/main"], "3" * 40)

    def test_nightly_preparation_accepts_successful_main_ci(self):
        self.run_release(command="nightly-ready")
        self.assertEqual((self.root / "outputs").read_text(), "skip=false\ncommit=" + COMMIT + "\n")

    def test_nightly_preparation_skips_a_stale_commit(self):
        self.references["heads/main"] = PREVIOUS
        self.run_release(command="nightly-ready")
        self.assertEqual((self.root / "outputs").read_text(), "skip=true\ncommit=" + COMMIT + "\n")

    def test_nightly_requires_successful_push_ci_from_this_repository(self):
        for problem in ("missing", "fork", "pull_request", "failed", "different-commit", "different-branch"):
            with self.subTest(problem=problem):
                run = {"head_sha": COMMIT, "head_branch": "main", "event": "push", "conclusion": "success",
                       "head_repository": {"full_name": REPOSITORY}}
                if problem == "fork":
                    run["head_repository"] = {"full_name": "someone/yuke"}
                elif problem == "pull_request":
                    run["event"] = "pull_request"
                elif problem == "failed":
                    run["conclusion"] = "failure"
                elif problem == "different-commit":
                    run["head_sha"] = PREVIOUS
                elif problem == "different-branch":
                    run["head_branch"] = "feature"
                self.ci = [] if problem == "missing" else [run]
                self.assertIn("requires successful push CI", self.run_release(command="nightly-ready", expected=1))
                self.assertFalse((self.root / "outputs").exists())

    def test_invalid_archives_do_not_hide_an_existing_release(self):
        self.seed_release()
        for problem in ("missing", "extra", "commit", "target", "dirty", "format", "version"):
            with self.subTest(problem=problem):
                for path in self.packages.iterdir():
                    path.unlink()
                self.write_packages("1.2.3-nightly.20261016+111111111111")
                expected = "exactly the four"
                if problem == "missing":
                    (self.packages / "yuke-aarch64-macos.tar.gz").unlink()
                elif problem == "extra":
                    (self.packages / "extra-file").write_text("not a release asset\n")
                else:
                    changes = {"commit": PREVIOUS, "target": "unsupported", "dirty": True, "format": 2,
                               "version": "1.2.3+dirty"}
                    self.write_packages("1.2.3-nightly.20261016+111111111111", {problem: changes[problem]})
                    expected = "nightly version" if problem == "version" else "build identity"
                self.assertIn(expected, self.run_release("nightly", expected=1))
                self.assertFalse(self.release["draft"])
                self.assertEqual(self.assets[0]["name"], "obsolete-asset")

    def test_development_versions_do_not_become_tagged_releases(self):
        self.references["tags/v1.2.3-dev"] = COMMIT
        self.write_packages("1.2.3-dev")
        self.assertIn("release version", self.run_release("v1.2.3-dev", expected=1))
        self.assertIsNone(self.release)

    def test_an_immutable_nightly_is_not_hidden_or_modified(self):
        self.seed_release()
        self.release["immutable"] = True
        self.write_packages("1.2.3-nightly.20261016+111111111111")
        self.assertIn("requires mutable releases", self.run_release("nightly", expected=1))
        self.assertFalse(self.release["draft"])
        self.assertEqual(self.references["tags/nightly"], PREVIOUS)
        self.assertEqual(self.assets[0]["name"], "obsolete-asset")

    def test_nightly_removes_obsolete_assets_across_all_pages(self):
        self.seed_release()
        self.assets = [{"id": index, "name": "old-" + str(index), "size": 3, "state": "uploaded"}
                       for index in range(101)]
        self.write_packages("1.2.3-nightly.20261016+111111111111")
        self.run_release("nightly")
        self.published("nightly", True)

    def test_a_success_response_must_confirm_publication(self):
        self.ignore_publish = True
        self.assertIn("did not publish", self.run_release(expected=1))
        self.assertTrue(self.release["draft"])
        self.assertEqual(set(self.uploaded), set(PLATFORMS))

    def test_permission_errors_do_not_look_like_an_absent_release(self):
        self.fail_release_read = True
        self.assertIn("HTTP 403", self.run_release(expected=1))
        self.assertIsNone(self.release)
        self.assertEqual(self.references["tags/v1.2.3"], COMMIT)


if __name__ == "__main__":
    unittest.main(verbosity=2)
