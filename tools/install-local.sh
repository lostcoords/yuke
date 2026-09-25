#!/bin/sh
set -eu

repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
bin_dir=${XDG_BIN_HOME:-"$HOME/.local/bin"}
link_path="$bin_dir/yuke"
launcher="$repo_root/tools/yuke-local"

(cd "$repo_root" && zig build --prefix "$repo_root/zig-out")
mkdir -p "$bin_dir"

# Replace an existing standalone install or symlink with the live checkout
# launcher. A real directory is refused so an accidental install cannot hide
# its contents.
if [ -d "$link_path" ] && [ ! -L "$link_path" ]; then
    printf 'Refusing to replace directory: %s\n' "$link_path" >&2
    exit 1
fi
rm -f "$link_path"
ln -s "$launcher" "$link_path"
printf 'Installed %s -> %s\n' "$link_path" "$launcher"
