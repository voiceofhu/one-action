#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

printf 'alpha\n' >"$test_dir/zeta.bin"
printf 'beta\n' >"$test_dir/alpha.bin"
bash "$PROJECT_ROOT/scripts/release/write-checksums.sh" \
  "$test_dir/SHA256SUMS" \
  "$test_dir/zeta.bin" \
  "$test_dir/alpha.bin" >/dev/null

first_name="$(awk 'NR == 1 { print $2 }' "$test_dir/SHA256SUMS")"
[[ "$first_name" == alpha.bin ]] || {
  printf 'Checksum entries are not sorted by basename.\n' >&2
  exit 1
}

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$test_dir" && sha256sum --check SHA256SUMS >/dev/null)
else
  (cd "$test_dir" && shasum -a 256 --check SHA256SUMS >/dev/null)
fi

printf '%s\n' 'Checksum helper test passed.'

