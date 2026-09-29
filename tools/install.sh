#!/bin/sh
set -eu

[ -n "${HOME:-}" ] || { printf 'HOME is not set.\n' >&2; exit 1; }

repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
bin_dir=$HOME/.local/bin
installed=$bin_dir/yuke
staged=$bin_dir/.yuke.$$

if [ -d "$installed" ] && [ ! -L "$installed" ]; then
    printf 'Refusing to replace directory: %s\n' "$installed" >&2
    exit 1
fi

(cd "$repo_root" && zig build -Doptimize=ReleaseFast)

# The lib directory goes first, so the new binary never starts without its files.
lib_dir=$HOME/.local/lib/yuke
staged_lib=$HOME/.local/lib/.yuke.$$
trap 'rm -f "$staged"; rm -rf "$staged_lib"' EXIT
mkdir -p "$HOME/.local/lib"
cp -R "$repo_root/zig-out/lib/yuke" "$staged_lib"
rm -rf "$lib_dir.old"
if [ -d "$lib_dir" ]; then mv "$lib_dir" "$lib_dir.old"; fi
mv "$staged_lib" "$lib_dir"
rm -rf "$lib_dir.old"

mkdir -p "$bin_dir"
mv -f "$repo_root/zig-out/bin/yuke" "$staged"
chmod 755 "$staged"
mv -f "$staged" "$installed"
printf 'Installed %s and %s\n' "$installed" "$lib_dir"

# Link the declarations into the profile. An editor then checks index.js against this build.
# The links follow the lib directory, so an upgrade keeps them current. An existing jsconfig.json belongs to the user.
config_home=${XDG_CONFIG_HOME:-}
case "$config_home" in /*) ;; *) config_home=$HOME/.config ;; esac
profile_name=${YUKE_APPNAME:-yuke}
case "$profile_name" in
    */* | *\\* | . | ..) printf 'Warning: YUKE_APPNAME is %s. The plugin types need a plain directory name.\n' "$profile_name" >&2 ;;
    *)
        profile=$config_home/$profile_name
        if mkdir -p "$profile" &&
            ln -sfn "$lib_dir/types/yuke.d.ts" "$profile/yuke.d.ts" &&
            ln -sfn "$lib_dir/types/yuke-modules.d.ts" "$profile/yuke-modules.d.ts" &&
            { [ -e "$profile/jsconfig.json" ] || [ -L "$profile/jsconfig.json" ] ||
                cp "$lib_dir/jsconfig.json" "$profile/jsconfig.json"; }; then
            printf 'Linked the plugin types into %s\n' "$profile"
        else
            printf 'Warning: could not link the plugin types into %s\n' "$profile" >&2
        fi
        ;;
esac

case ":${PATH:-}:" in
    *":$bin_dir:"*) ;;
    *) printf '\n%s is not in PATH. Add it:\n\n  export PATH="$HOME/.local/bin:$PATH"\n' "$bin_dir" ;;
esac
