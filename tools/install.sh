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

download() {
  curl --proto '=https' --proto-redir '=https' -fsSL -o "$2" "$1" || fail "cannot download $1."
}

install_yuke() {
  [ "$#" -le 1 ] || fail 'usage: install.sh [archive.tar.gz]'
  local repo=lostcoords/yuke channel="${YUKE_CHANNEL:-stable}" bin_dir="${HOME}/.local/bin" os arch name url archive version
  local sum=(sha256sum)
  lib_dir="${HOME}/.local/lib/yuke"
  case "$(uname -m)" in arm64 | aarch64) arch=aarch64 ;; x86_64 | amd64) arch=x86_64 ;; *) fail "no package for $(uname -m)." ;; esac
  case "$(uname -s)" in Darwin) os=macos ;; Linux) os=linux-musl ;; *) fail "no package for $(uname -s)." ;; esac

  mkdir -p "${HOME}/.local"
  staging="$(mktemp -d "${HOME}/.local/.yuke-install.XXXXXX")"
  trap 'rm -rf "${staging}"' EXIT
  if [ "$#" = 1 ]; then
    archive="$1"
  else
    if [ -n "${YUKE_VERSION:-}" ]; then
      url="download/v${YUKE_VERSION#v}"
    else
      case "${channel}" in
        stable) url=latest/download ;;
        nightly) url=download/nightly ;;
        *) fail 'YUKE_CHANNEL must be stable or nightly.' ;;
      esac
    fi
    url="https://github.com/${repo}/releases/${url}"
    name="yuke-${arch}-${os}.tar.gz"
    archive="${staging}/${name}"
    download "${url}/SHA256SUMS" "${staging}/SHA256SUMS"
    download "${url}/${name}" "${archive}"
    # Linux has sha256sum and macOS has shasum. Both check the same "DIGEST  NAME" lines.
    command -v sha256sum > /dev/null || sum=(shasum -a 256)
    grep -F "  ${name}" "${staging}/SHA256SUMS" | (cd "${staging}" && "${sum[@]}" -c - > /dev/null) ||
      fail "${name} does not match its checksum in SHA256SUMS."
  fi
  # A broken download or binary stops here, before the working installation changes.
  tar -xzf "${archive}" -C "${staging}" || fail 'the download is not a yuke package.'
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
