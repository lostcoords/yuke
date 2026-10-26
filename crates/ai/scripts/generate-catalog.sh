#!/usr/bin/env bash
# Translate the trusted Yuke catalog. An input file skips the download.
set -euo pipefail

if (( $# > 2 )); then
    printf 'usage: %s [catalog.json [output.rs]]\n' "$0" >&2
    exit 2
fi

scripts=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
out=${2:-$scripts/../src/catalog/generated.rs}
tmp=$(mktemp -d "$(dirname -- "$out")/.catalog.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
trap 'exit 1' HUP INT TERM

if (( $# == 0 )); then
    curl --fail --silent --show-error --location --compressed \
        --max-time 60 'https://catalog.yuke.sh/v1/catalog?executable=true' > "$tmp/catalog.json"
    input=$tmp/catalog.json
else
    input=$1
fi

jq --exit-status --raw-output --from-file "$scripts/catalog.jq" "$input" > "$tmp/catalog.rs"
"${RUSTFMT:-rustfmt}" --edition 2024 "$tmp/catalog.rs"
# The temporary file shares the output filesystem, so rename replaces it atomically.
chmod 644 "$tmp/catalog.rs"
mv -f -- "$tmp/catalog.rs" "$out"
printf 'generated %s\n' "$out"
