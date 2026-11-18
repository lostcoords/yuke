#!/usr/bin/env bash
# Keep all execution in the final function call so a truncated script cannot install a partial download.
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# An editor checks the plugins of the profile against the installed API. A tsconfig.json of the user stays.
configure_editor() {
  local root profile
  root="${XDG_CONFIG_HOME:-}"
  case "${root}" in /*) ;; *) root="${HOME}/.config" ;; esac
  profile="${root}/${YUKE_APPNAME:-yuke}"
  mkdir -p "${profile}"
  [ -e "${profile}/tsconfig.json" ] || cat > "${profile}/tsconfig.json" <<JSON
{
  "extends": "${lib_dir}/tsconfig.json",
  "include": ["./**/*.ts"],
  "exclude": ["./node_modules"]
}
JSON
}

install_yuke() {
  [ "$#" -le 1 ] || fail 'usage: install.sh [archive.tar.gz]'
  local repo=lostcoords/yuke channel="${YUKE_CHANNEL:-stable}" bin_dir="${HOME}/.local/bin" os arch url archive version
  lib_dir="${HOME}/.local/lib/yuke"
  case "$(uname -m)" in arm64 | aarch64) arch=aarch64 ;; x86_64 | amd64) arch=x86_64 ;; *) fail "no package for $(uname -m)." ;; esac
  case "$(uname -s)" in Darwin) os=macos ;; Linux) os=linux-musl ;; *) fail "no package for $(uname -s)." ;; esac

  mkdir -p "${HOME}/.local"
  staging="$(mktemp -d "${HOME}/.local/.yuke-install.XXXXXX")"
  trap 'rm -rf "${staging}"' EXIT
  if [ "$#" = 1 ]; then
    archive="$1"
  else
    case "${channel}" in
      stable) url="https://github.com/${repo}/releases/latest/download" ;;
      nightly) url="https://github.com/${repo}/releases/download/nightly" ;;
      *) fail 'YUKE_CHANNEL must be stable or nightly.' ;;
    esac
    archive="${staging}/yuke.tar.gz"
    curl --proto '=https' --proto-redir '=https' -fsSL -o "${archive}" "${url}/yuke-${arch}-${os}.tar.gz" ||
      fail "cannot download the ${channel} release of ${repo}."
  fi
  # A broken download or binary stops here, before the working installation changes.
  tar -xzf "${archive}" -C "${staging}"
  version="$("${staging}/bin/yuke" --version)" || fail 'the new yuke binary does not run on this machine.'

  mkdir -p "${bin_dir}" "${lib_dir%/*}"
  rm -rf "${lib_dir}"
  mv "${staging}/lib/yuke" "${lib_dir}"
  mv -f "${staging}/bin/yuke" "${bin_dir}/yuke"
  configure_editor
  # Agents that read ~/.agents/skills, yuke too, find the skill of the installed release there.
  mkdir -p "${HOME}/.agents/skills"
  ln -sfn "${lib_dir}/skills/yuke" "${HOME}/.agents/skills/yuke"

  printf 'Installed %s/yuke (%s)\n' "${bin_dir}" "${version#yuke }"
  case ":${PATH}:" in
    *":${bin_dir}:"*) ;;
    *) printf 'Add ~/.local/bin to PATH in your shell configuration.\n' ;;
  esac
  printf 'Run yuke --help for supported commands.\n'
}

install_yuke "$@"
