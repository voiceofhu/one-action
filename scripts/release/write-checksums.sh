#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -lt 2 ]]; then
  printf '%s\n' 'usage: write-checksums.sh OUTPUT FILE...' >&2
  exit 1
fi

output_file="$1"
shift
output_dir="$(dirname -- "$output_file")"
[[ -d "$output_dir" ]] || {
  printf 'Output directory does not exist: %s\n' "$output_dir" >&2
  exit 1
}

if command -v sha256sum >/dev/null 2>&1; then
  checksum() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  checksum() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  printf '%s\n' 'sha256sum or shasum is required' >&2
  exit 1
fi

temporary_file="$(mktemp "$output_dir/.SHA256SUMS.XXXXXX")"
trap 'rm -f "$temporary_file"' EXIT
declare -a names=()

for artifact in "$@"; do
  [[ -f "$artifact" ]] || {
    printf 'Artifact does not exist: %s\n' "$artifact" >&2
    exit 1
  }
  name="$(basename -- "$artifact")"
  for existing_name in ${names[@]+"${names[@]}"}; do
    if [[ "$existing_name" == "$name" ]]; then
      printf 'Duplicate artifact basename: %s\n' "$name" >&2
      exit 1
    fi
  done
  names+=("$name")
  printf '%s  %s\n' "$(checksum "$artifact")" "$name" >>"$temporary_file"
done

LC_ALL=C sort -k2,2 "$temporary_file" -o "$temporary_file"
mv "$temporary_file" "$output_file"
trap - EXIT
printf 'Wrote %s for %d artifact(s).\n' "$output_file" "$#"
