#!/usr/bin/env bash
# Verifies the One Browser Chromium runtime packages downloaded from the
# private staging release and assembles the public Release: every file must be
# one-browser-chromium-<platform>-<arch>-<asset_version>-<sha256>.tar.gz whose
# real SHA-256 equals the one in its name, one package per platform/arch, and
# every package must carry the same .one-browser-chromium-version. Moves the
# packages into OUTPUT_DIR, writes OUTPUT_DIR/SHA256SUMS and the release notes.
#
#   VERSION=<v> CHROMIUM_REF=<sha> browser-runtime-assets.sh STAGING_DIR OUTPUT_DIR NOTES_FILE
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGE_PATTERN='^one-browser-chromium-(macos|windows|linux)-(arm64|x64)-((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))-([0-9a-f]{64})\.tar\.gz$'

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" -eq 3 ]] || die 'usage: browser-runtime-assets.sh STAGING_DIR OUTPUT_DIR NOTES_FILE'
staging_dir=$1
output_dir=$2
notes_file=$3
: "${VERSION:?VERSION is required}"
: "${CHROMIUM_REF:?CHROMIUM_REF is required}"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  die 'VERSION must be an unprefixed three-component numeric version'
[[ "$CHROMIUM_REF" =~ ^[0-9a-f]{40}$ ]] || die 'CHROMIUM_REF must be an exact commit SHA'
[[ -d "$staging_dir" ]] || die "staging directory does not exist: $staging_dir"
[[ -d "$output_dir" ]] || die "output directory does not exist: $output_dir"
[[ -z "$(find "$output_dir" -mindepth 1 -print -quit)" ]] || die "output directory must be empty: $output_dir"

if command -v sha256sum >/dev/null 2>&1; then
  checksum() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  checksum() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  die 'sha256sum or shasum is required'
fi

declare -a names=() targets=() rows=()
chromium_version=
while IFS= read -r -d '' entry; do
  name="${entry##*/}"
  [[ -f "$entry" && ! -L "$entry" ]] || die "staging entry is not a regular file: $name"
  [[ "$name" =~ $PACKAGE_PATTERN ]] || die "unexpected staging asset: $name"
  platform=${BASH_REMATCH[1]}
  arch=${BASH_REMATCH[2]}
  expected_sha=${BASH_REMATCH[7]}
  for target in ${targets[@]+"${targets[@]}"}; do
    [[ "$target" != "$platform-$arch" ]] || die "more than one package for $platform-$arch"
  done
  actual_sha="$(checksum "$entry")"
  [[ "$actual_sha" == "$expected_sha" ]] ||
    die "SHA-256 mismatch for $name: file is $actual_sha"
  # The packager appends this file last; reading it streams the whole archive,
  # which also proves the gzip/tar stream is intact.
  package_version="$(tar -xzOf "$entry" .one-browser-chromium-version 2>/dev/null | tr -d '\r\n')" ||
    die "$name does not contain .one-browser-chromium-version"
  [[ "$package_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "$name has an invalid Chromium version: ${package_version:-<empty>}"
  [[ -z "$chromium_version" || "$chromium_version" == "$package_version" ]] ||
    die "packages disagree on the Chromium version: $chromium_version vs $package_version ($name)"
  chromium_version=$package_version
  size="$(wc -c <"$entry" | tr -d '[:space:]')"
  size_label="$(awk -v bytes="$size" 'BEGIN { printf "%.1f MiB", bytes / 1048576 }')"
  names+=("$name")
  targets+=("$platform-$arch")
  rows+=("| $platform | $arch | \`$name\` | $size_label ($size bytes) | \`$actual_sha\` |")
done < <(find "$staging_dir" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)

[[ "${#names[@]}" -ge 1 ]] || die "staging release has no runtime packages: $staging_dir"

for name in "${names[@]}"; do
  mv -- "$staging_dir/$name" "$output_dir/$name"
done
bash "$PROJECT_ROOT/scripts/release/write-checksums.sh" \
  "$output_dir/SHA256SUMS" "${names[@]/#/$output_dir/}" >/dev/null

{
  printf 'One Browser Runtime %s\n\n' "$VERSION"
  printf -- '- Chromium: %s\n' "$chromium_version"
  printf -- '- Source: voiceofhu/one-browser-chromium@%s\n\n' "$CHROMIUM_REF"
  printf '%s\n' '| Platform | Arch | Package | Size | SHA-256 |' '| --- | --- | --- | --- | --- |'
  printf '%s\n' "${rows[@]}"
  printf '\n%s\n' 'Verify with `sha256sum --check SHA256SUMS`.'
} >"$notes_file"

printf 'Verified %d One Browser Runtime package(s), Chromium %s.\n' "${#names[@]}" "$chromium_version"
