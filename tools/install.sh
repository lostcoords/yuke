#!/bin/sh
# Build this tree and install it as ../yuke-cloud/lib/install.sh installs a release: ~/.local/bin/yuke and ~/.local/lib/yuke.
# The install and link steps match that script, so keep the two in step.
set -eu

[ -n "${HOME:-}" ] || { printf 'error HOME is not set.\n' >&2; exit 1; }

repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
bin_dir=$HOME/.local/bin
lib_dir=$HOME/.local/lib/yuke

tmp=$(mktemp -d)
staged=$bin_dir/.yuke.$$
staged_lib=${lib_dir%/*}/.yuke.$$
trap 'rm -rf "$tmp" "$staged" "$staged_lib"' EXIT

# A separate prefix leaves zig-out/ to the development build.
(cd "$repo_root" && zig build -Doptimize=ReleaseFast --prefix "$tmp")

# The lib directory goes first, so the new binary never starts without its files.
# A rename cannot replace a non-empty directory. So the old directory moves aside first.
mkdir -p "${lib_dir%/*}"
mv "$tmp/lib/yuke" "$staged_lib"
rm -rf "$lib_dir.old"
if [ -d "$lib_dir" ]; then mv "$lib_dir" "$lib_dir.old"; fi
mv "$staged_lib" "$lib_dir"
rm -rf "$lib_dir.old"

# A rename in one directory is atomic, so a running yuke keeps the old inode.
mkdir -p "$bin_dir"
mv -f "$tmp/bin/yuke" "$staged"
chmod 755 "$staged"
mv -f "$staged" "$bin_dir/yuke"
printf 'installed %s/yuke  %s\n' "$bin_dir" "$("$bin_dir/yuke" --version)"

# Link the editor options and the plugin API declarations into the profile. The links follow the lib directory.
# jsconfig.json belongs to the user once it exists; the one this writes only extends the linked options.
config_home=${XDG_CONFIG_HOME:-}
case "$config_home" in /*) ;; *) config_home=$HOME/.config ;; esac
profile_name=${YUKE_APPNAME:-yuke}
case "$profile_name" in
    */* | *\\* | . | ..)
        printf 'warning YUKE_APPNAME is %s. The plugin types need a plain directory name.\n' "$profile_name" ;;
    *)
        profile=$config_home/$profile_name
        if mkdir -p "$profile" &&
            ln -sfn "$lib_dir/jsconfig.json" "$profile/yuke.jsconfig.json" &&
            ln -sfn "$lib_dir/types/yuke.d.ts" "$profile/yuke.d.ts" &&
            ln -sfn "$lib_dir/types/yuke-modules.d.ts" "$profile/yuke-modules.d.ts" &&
            { [ -e "$profile/jsconfig.json" ] || [ -L "$profile/jsconfig.json" ] ||
                printf '{ "extends": "./yuke.jsconfig.json" }\n' > "$profile/jsconfig.json"; }; then
            printf 'linked the plugin types into %s\n' "$profile"
        else
            printf 'warning could not link the plugin types into %s\n' "$profile"
        fi
        ;;
esac

case ":${PATH:-}:" in
    *":$bin_dir:"*) ;;
    *)
        # The user copies this line into a shell file, so $HOME and $PATH stay unexpanded.
        printf '\n%s is not in your PATH. Add it:\n\n  export PATH="$HOME/.local/bin:$PATH"\n' "$bin_dir"
        exit 0
        ;;
esac
found=$(command -v yuke || true)
if [ -n "$found" ] && [ "$found" != "$bin_dir/yuke" ]; then
    printf '\nwarning another yuke comes first in PATH: %s\n' "$found"
fi
