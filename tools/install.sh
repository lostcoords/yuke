#!/usr/bin/env bash
# Keep all execution in the final function call so a truncated script cannot install a partial download.
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

probe_release() {
  local result code
  result="$(curl --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 60 \
    -sIL -o /dev/null -w '%{http_code} %{url_effective}' "$1")" || fail 'cannot reach GitHub.'
  code="${result%% *}"
  [ "${code}" = 200 ] || fail "GitHub answered ${code}; ${repo} needs a public ${channel} release."
  landed="${result#* }"
}

resolve_release() {
  case "${channel}" in
    stable)
      probe_release "https://github.com/${repo}/releases/latest"
      case "${landed}" in
        "https://github.com/${repo}/releases/tag/"*) tag="${landed##*/}" ;;
        *) fail "${repo} has no stable release." ;;
      esac
      ;;
    nightly)
      probe_release "https://github.com/${repo}/releases/tag/nightly"
      tag=nightly
      ;;
    *) fail 'YUKE_CHANNEL must be stable or nightly.' ;;
  esac
  [[ "${tag}" =~ ^[a-zA-Z0-9._+-]+$ ]] || fail 'the release tag contains unsupported characters.'
}

check_package_path() {
  case "$1" in
    /* | ../* | */../* | */.. | *\\*) fail 'the package contains an unsafe path.' ;;
    bin | bin/ | bin/yuke | lib | lib/ | lib/yuke | lib/yuke/ | lib/yuke/*) ;;
    *) fail "the package contains an unexpected path: $1" ;;
  esac
}

extract_archive() {
  local archive="$1" name
  tar -tzf "${archive}" > "${staging}/entries" || fail 'cannot read the package archive.'
  while IFS= read -r name; do
    check_package_path "${name}"
  done < "${staging}/entries"
  # Packages contain only regular files and directories, never links or device files.
  tar -tvzf "${archive}" > "${staging}/entry-types"
  if ! awk 'substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" { exit 1 }' "${staging}/entry-types"; then
    fail 'the archive contains a link or special file.'
  fi
  mkdir "${staging}/package"
  tar -xzf "${archive}" -C "${staging}/package"
}

cleanup() {
  local status="$?" recovery_failed=false
  trap - EXIT
  if [ "${committed}" = false ]; then
    if [ "${new_library}" = true ] && ! mv "${lib_dir}" "${staging}/failed-library"; then
      recovery_failed=true
    fi
    if [ "${recovery_failed}" = false ] && [ -d "${staging}/previous-library" ]; then
      if ! mv "${staging}/previous-library" "${lib_dir}"; then recovery_failed=true; fi
    fi
  fi
  if [ "${recovery_failed}" = true ]; then
    printf 'error: recovery files remain at %s. Restore the previous library to %s manually.\n' "${staging}" "${lib_dir}" >&2
    status=1
  elif ! rm -rf "${staging}"; then
    printf 'warning: could not remove %s. The installation files are already restored or committed.\n' "${staging}" >&2
  fi
  rmdir "${lock}" || printf 'warning: could not remove %s\n' "${lock}" >&2
  exit "${status}"
}

configure_editor() {
  local root name profile link
  root="${XDG_CONFIG_HOME:-}"
  case "${root}" in /*) ;; *) root="${HOME}/.config" ;; esac
  name="${YUKE_APPNAME:-yuke-rs}"
  case "${name}" in
    . | .. | */* | *\\*) printf 'warning: YUKE_APPNAME needs a plain profile name; editor configuration stays unchanged.\n' >&2; return ;;
  esac
  profile="${root}/${name}"
  link="${profile}/yuke-library"
  if ! mkdir -p "${profile}"; then
    printf 'warning: cannot create %s; editor configuration stays unchanged.\n' "${profile}" >&2
    return
  fi
  if [ -e "${link}" ] || [ -L "${link}" ]; then
    if [ ! -L "${link}" ] || [ "$(readlink "${link}")" != "${lib_dir}" ]; then
      printf 'warning: %s belongs to the user; it stays unchanged.\n' "${link}" >&2
      return
    fi
  elif ! ln -s "${lib_dir}" "${link}"; then
    printf 'warning: cannot link %s.\n' "${link}" >&2
    return
  fi
  if [ ! -e "${profile}/tsconfig.json" ] && [ ! -L "${profile}/tsconfig.json" ]; then
    if ! (set -C; cat > "${profile}/tsconfig.json" <<'JSON'
{
  "extends": "./yuke-library/tsconfig.json",
  "include": ["./**/*.ts"],
  "exclude": ["./yuke-library", "./node_modules"]
}
JSON
    ); then
      printf 'warning: cannot create %s/tsconfig.json.\n' "${profile}" >&2
    fi
  fi
}

remove_obsolete_skill_link() {
  local skill="${HOME}/.agents/skills/yuke"
  # The shared skill directory can contain user files. Remove only the old installer's exact link.
  if [ -L "${skill}" ] && [ "$(readlink "${skill}")" = "${lib_dir}/skills/yuke" ]; then
    if ! rm "${skill}"; then
      printf 'warning: could not remove the obsolete skill link at %s.\n' "${skill}" >&2
    fi
  fi
}

install_yuke() {
  [ "$#" -le 1 ] || fail 'usage: install.sh [archive.tar.gz]'
  case "${HOME:-}" in /*) ;; *) fail 'HOME must be an absolute directory.' ;; esac
  repo=lostcoords/yuke
  channel="${YUKE_CHANNEL:-stable}"
  bin_dir="${HOME}/.local/bin"
  lib_dir="${HOME}/.local/lib/yuke"
  command -v tar >/dev/null || fail 'tar is required.'

  mkdir -p "${HOME}/.local"
  lock="${HOME}/.local/.yuke-install.lock"
  mkdir "${lock}" 2>/dev/null || fail "another installer holds ${lock}; check it before removing the lock."
  if ! staging="$(mktemp -d "${HOME}/.local/.yuke-install.XXXXXX")"; then
    rmdir "${lock}"
    fail 'cannot create an installation staging directory.'
  fi
  committed=false
  new_library=false
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  local archive asset os arch base version expected_target package_target package_format
  os="$(uname -s)"
  arch="$(uname -m)"
  case "${arch}" in arm64 | aarch64) arch=aarch64 ;; x86_64 | amd64) arch=x86_64 ;; *) fail "no package for ${arch}." ;; esac
  case "${os}" in
    Darwin) os=macos; expected_target="${arch}-apple-darwin" ;;
    Linux) os=linux-musl; expected_target="${arch}-unknown-linux-musl" ;;
    *) fail "no package for ${os}." ;;
  esac
  if [ "$#" = 1 ]; then
    archive="$1"
    [ -f "${archive}" ] || fail 'the local package must be an archive file.'
  else
    command -v curl >/dev/null || fail 'curl is required for downloads.'
    resolve_release
    asset="yuke-${arch}-${os}.tar.gz"
    archive="${staging}/${asset}"
    base="https://github.com/${repo}/releases/download/${tag}"
    curl --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 300 \
      -fsSL -o "${archive}" "${base}/${asset}"
  fi
  extract_archive "${archive}"

  local package="${staging}/package" file
  for file in bin/yuke lib/yuke/modules/tools.ts lib/yuke/modules/plugins.ts \
    lib/yuke/types/globals.d.ts lib/yuke/tsconfig.json \
    lib/yuke/protocol/bindings/ClientRequest.ts lib/yuke/protocol/README.md \
    lib/yuke/LICENSE.md lib/yuke/build.json; do
    [ -f "${package}/${file}" ] && [ ! -L "${package}/${file}" ] || fail "the package has no regular ${file}."
  done
  package_format="$(sed -n 's/^[[:space:]]*"format": \([0-9][0-9]*\)[[:space:],]*$/\1/p' "${package}/lib/yuke/build.json")"
  [ "${package_format}" = 1 ] || fail 'unsupported package format.'
  package_target="$(sed -n 's/^[[:space:]]*"target": "\([^"]*\)".*/\1/p' "${package}/lib/yuke/build.json")"
  [ "${package_target}" = "${expected_target}" ] || fail 'the package target does not match this machine.'
  version="$(sed -n 's/^[[:space:]]*"version": "\([^"]*\)".*/\1/p' "${package}/lib/yuke/build.json")"
  [ -n "${version}" ] || fail 'the package has no build version.'
  [ "$("${package}/bin/yuke" --version)" = "yuke ${version}" ] || fail 'the staged binary does not run or has the wrong version.'
  if [ "$#" = 0 ] && [ "${channel}" = stable ]; then
    [ "v${version}" = "${tag}" ] || fail 'the stable tag does not match the package version.'
  fi

  mkdir -p "${bin_dir}" "${lib_dir%/*}"
  [ ! -L "${lib_dir}" ] || fail "${lib_dir} is a symlink; move it before installation."
  if [ -e "${bin_dir}/yuke" ] || [ -L "${bin_dir}/yuke" ]; then
    [ ! -d "${bin_dir}/yuke" ] || fail "${bin_dir}/yuke is a directory."
    printf 'Replacing %s/yuke\n' "${bin_dir}"
  fi
  if [ -e "${lib_dir}" ]; then
    [ -d "${lib_dir}" ] || fail "${lib_dir} is not a directory."
    mv "${lib_dir}" "${staging}/previous-library"
  fi
  mv "${package}/lib/yuke" "${lib_dir}"
  new_library=true
  mv -f "${package}/bin/yuke" "${bin_dir}/yuke"
  committed=true

  configure_editor
  remove_obsolete_skill_link
  printf 'Installed %s/yuke (%s)\n' "${bin_dir}" "${version}"
  case ":${PATH}:" in
    *":${bin_dir}:"*) ;;
    *) printf 'Add ~/.local/bin to PATH in your shell configuration.\n' ;;
  esac
  printf 'Run yuke --help for supported commands. The terminal interface is not available.\n'
}

install_yuke "$@"
