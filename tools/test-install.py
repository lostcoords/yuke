#!/usr/bin/env python3
"""Check local build stamps and the installed version without compiling or touching HOME."""
import os
import pathlib
import re
import shutil
import subprocess
import tempfile

installer = pathlib.Path(__file__).with_name("install.sh")
subprocess.run(["sh", "-n", str(installer)], check=True)
with tempfile.TemporaryDirectory(prefix="yuke-install-test-") as directory:
    root = pathlib.Path(directory)
    repo = root / "repo"
    tools = repo / "tools"
    tools.mkdir(parents=True)
    (repo / ".jj").mkdir()
    (repo / "build.zig.zon").write_text('.{\n    .version = "0.0.1-dev",\n}\n')
    shutil.copyfile(installer, tools / "install.sh")
    fake_bin = root / "bin"
    fake_bin.mkdir()
    scripts = {
        "jj": '#!/bin/sh\n[ "$*" = "log -r @ --no-graph -T commit_id.short(12)" ] || exit 4\nprintf abcdef123456\n',
        "git": '#!/bin/sh\necho "git must not run in a jj checkout" >&2\nexit 99\n',
        "zig": r'''#!/bin/sh
set -eu
version=
prefix=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -Dversion-string=*) version=${1#-Dversion-string=} ;;
        --prefix) shift; prefix=$1 ;;
    esac
    shift
done
[ -n "$version" ] && [ -n "$prefix" ]
mkdir -p "$prefix/bin" "$prefix/lib/yuke/types" "$prefix/lib/yuke/skills/yuke"
printf '#!/bin/sh\necho "yuke %s"\n' "$version" > "$prefix/bin/yuke"
: > "$prefix/lib/yuke/jsconfig.json"
: > "$prefix/lib/yuke/types/yuke.d.ts"
: > "$prefix/lib/yuke/types/yuke-modules.d.ts"
''',
    }
    for name, content in scripts.items():
        path = fake_bin / name
        path.write_text(content)
        path.chmod(0o700)
    home = root / "home"
    env = {**os.environ, "HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config"),
           "YUKE_APPNAME": "yuke", "PATH": str(fake_bin) + ":/usr/bin:/bin"}
    result = subprocess.run(["sh", str(tools / "install.sh")], env=env, check=True,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    version = subprocess.check_output([str(home / ".local/bin/yuke"), "--version"], text=True).strip()
    assert re.fullmatch(r"yuke 0\.0\.1-dev\+abcdef123456\.b\d{14}", version), version
    assert version in result.stdout, result.stdout
    assert (home / ".config/yuke/yuke.d.ts").is_symlink(), "the installer did not refresh plugin types"
    print("Installer stamp check passed:", version)
