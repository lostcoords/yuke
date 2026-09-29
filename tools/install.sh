#!/bin/sh
set -eu

[ -n "${HOME:-}" ] || { printf 'HOME is not set.\n' >&2; exit 1; }

repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
bin_dir=$HOME/.local/bin
installed=$bin_dir/yuke
staged=$bin_dir/.yuke.$$
trap 'rm -f "$staged"' EXIT

if [ -d "$installed" ] && [ ! -L "$installed" ]; then
    printf 'Refusing to replace directory: %s\n' "$installed" >&2
    exit 1
fi

(cd "$repo_root" && zig build -Doptimize=ReleaseFast)
mkdir -p "$bin_dir"
mv -f "$repo_root/zig-out/bin/yuke" "$staged"
chmod 755 "$staged"
mv -f "$staged" "$installed"
printf 'Installed %s\n' "$installed"

"$installed" types >/dev/null 2>&1 ||
    printf 'Warning: could not write the plugin types; run yuke types.\n' >&2

case ":${PATH:-}:" in
    *":$bin_dir:"*) ;;
    *) printf '\n%s is not in PATH. Add it:\n\n  export PATH="$HOME/.local/bin:$PATH"\n' "$bin_dir" ;;
esac
