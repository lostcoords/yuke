#!/usr/bin/env python3
"""Publish tested package archives through a draft GitHub release."""

import argparse
import json
import os
from pathlib import Path
import re
import sys
import tarfile
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

# Release checks must not add cache files to a clean checkout.
sys.dont_write_bytecode = True
from package import TARGETS


class GitHub:
    def __init__(self):
        self.repository = os.environ["GITHUB_REPOSITORY"]
        self.base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer " + os.environ["GH_TOKEN"],
            "X-GitHub-Api-Version": "2026-03-10",
        }

    def request(self, method, path, data=None):
        url = path if path.startswith(("https://", "http://")) else self.base + "/repos/" + self.repository + "/" + path
        headers = dict(self.headers)
        if isinstance(data, bytes):
            headers["Content-Type"] = "application/gzip"
        elif data is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(data).encode()
        try:
            with urlopen(Request(url, data=data, headers=headers, method=method), timeout=120) as response:
                body = response.read()
                return json.loads(body) if body else None
        except HTTPError as error:
            if method == "GET" and error.code == 404:
                return None
            raise RuntimeError("GitHub " + method + " " + path + ": HTTP " + str(error.code)) from None

    def commit(self, reference):
        value = self.request("GET", "git/ref/" + reference)
        if value is None:
            return None
        value = value["object"]
        while value["type"] == "tag":
            value = self.request("GET", "git/tags/" + value["sha"])["object"]
        if value["type"] != "commit":
            raise RuntimeError("the reference does not name a commit: " + reference)
        return value["sha"]

    def successful_ci(self, commit):
        query = urlencode({"branch": "main", "event": "push", "status": "success", "head_sha": commit, "per_page": 1})
        result = self.request("GET", "actions/workflows/ci.yml/runs?" + query)
        return result is not None and any(
            run["head_sha"] == commit and run["head_branch"] == "main" and run["event"] == "push"
            and run["conclusion"] == "success" and run["head_repository"]["full_name"] == self.repository
            for run in result["workflow_runs"]
        )

    def pages(self, path):
        page = 1
        while True:
            values = self.request("GET", path + "?per_page=100&page=" + str(page))
            if values is None:
                raise RuntimeError("the GitHub resource disappeared: " + path)
            yield from values
            if len(values) < 100:
                return
            page += 1

    def release(self, tag):
        # The tag endpoint only promises published releases. The list also contains drafts for this write token.
        return next((release for release in self.pages("releases") if release["tag_name"] == tag), None)


def nightly_ready(github, commit):
    if github.commit("heads/main") != commit:
        print("main moved past " + commit + "; skip this nightly")
        return False
    if not github.successful_ci(commit):
        raise RuntimeError("nightly requires successful push CI on main for " + commit)
    return True


def archives(directory, commit, tag):
    expected = {"yuke-" + platform + ".tar.gz": target for target, platform in TARGETS.items()}
    if {path.name for path in directory.iterdir()} != set(expected):
        raise RuntimeError("the release needs exactly the four platform archives")
    versions = set()
    for name, target in expected.items():
        with tarfile.open(directory / name, "r:gz") as archive:
            identity = json.load(archive.extractfile("lib/yuke/build.json"))
        if (identity["format"] != 1 or identity["dirty"] is not False
                or identity["commit"] != commit or identity["target"] != target):
            raise RuntimeError("the archive has the wrong build identity: " + name)
        version = identity["version"]
        if tag == "nightly":
            if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}\+" + commit[:12], version) is None:
                raise RuntimeError("the archive has the wrong nightly version: " + name)
        elif tag != "v" + version or "-dev" in version.split("+", 1)[0]:
            raise RuntimeError("the tag does not match a release version: " + name)
        versions.add(version)
    if len(versions) != 1:
        raise RuntimeError("the archives have different build versions")
    return [directory / name for name in sorted(expected)]


def publish(github, directory, commit, tag):
    packages = archives(directory, commit, tag)
    nightly = tag == "nightly"
    if nightly:
        if not nightly_ready(github, commit):
            return
    elif github.commit("tags/" + quote(tag, safe="")) != commit:
        raise RuntimeError("the release tag moved or does not exist")

    release = github.release(tag)
    if release is not None and not nightly and not release["draft"]:
        raise RuntimeError("the tagged release is already published; use a new version")
    if release is not None and release.get("immutable", False):
        raise RuntimeError("the rolling nightly requires mutable releases")
    prerelease = nightly or "-" in tag.split("+", 1)[0]
    description = {
        "tag_name": tag, "draft": True, "prerelease": prerelease,
        "make_latest": "false" if prerelease else "legacy",
        "name": "Nightly (" + commit[:12] + ")" if nightly else tag,
        "body": "Built from commit `" + commit + "`.",
    }
    # The versioned tag fixes its commit. An explicit target can require workflow permissions that this token lacks.
    if nightly:
        description["target_commitish"] = commit
    if release is None:
        release = github.request("POST", "releases", description)
    else:
        release = github.request("PATCH", "releases/" + str(release["id"]), description)
    release_id = release["id"]
    for asset in list(github.pages("releases/" + str(release_id) + "/assets")):
        github.request("DELETE", "releases/assets/" + str(asset["id"]))
    upload = release["upload_url"].split("{", 1)[0]
    for package in packages:
        github.request("POST", upload + "?" + urlencode({"name": package.name}), package.read_bytes())
    uploaded = list(github.pages("releases/" + str(release_id) + "/assets"))
    expected = {package.name: package.stat().st_size for package in packages}
    if (len(uploaded) != len(expected) or {asset["name"]: asset["size"] for asset in uploaded} != expected
            or any(asset["state"] != "uploaded" for asset in uploaded)):
        raise RuntimeError("the draft does not contain the four complete archives")

    if nightly:
        if not nightly_ready(github, commit):
            return
        if github.commit("tags/nightly") is None:
            github.request("POST", "git/refs", {"ref": "refs/tags/nightly", "sha": commit})
        else:
            github.request("PATCH", "git/refs/tags/nightly", {"sha": commit, "force": True})
        if not nightly_ready(github, commit):
            return
    if github.commit("tags/" + quote(tag, safe="")) != commit:
        raise RuntimeError("the release tag moved; the draft stays unpublished")
    published = github.request("PATCH", "releases/" + str(release_id), {
        "draft": False, "prerelease": prerelease, "make_latest": "false" if prerelease else "legacy",
    })
    if published["draft"] or published["prerelease"] != prerelease:
        raise RuntimeError("GitHub did not publish the release with the requested status")
    print("published " + tag + " from " + commit)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("nightly-ready", "publish"))
    parser.add_argument("--commit", required=True)
    parser.add_argument("--tag")
    parser.add_argument("--directory", type=Path, default=Path("dist"))
    args = parser.parse_args()
    if re.fullmatch(r"[0-9a-f]{40}", args.commit) is None:
        parser.error("--commit needs the full source commit")
    github = GitHub()
    if args.command == "nightly-ready":
        ready = nightly_ready(github, args.commit)
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write("skip=" + str(not ready).lower() + "\ncommit=" + args.commit + "\n")
    elif not args.tag:
        parser.error("publication needs --tag")
    else:
        publish(github, args.directory, args.commit, args.tag)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, KeyError, tarfile.TarError) as error:
        sys.exit(str(error))
