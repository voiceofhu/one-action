#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

[[ "$#" -eq 2 ]] || die "usage: resolve-ref.sh OWNER/REPOSITORY REF"
repository="$1"
source_ref="$2"

require_tool curl
require_tool jq
normalize_github_token
validate_repository "$repository"
validate_ref "$source_ref"

encoded_ref="$(jq -rn --arg value "$source_ref" '$value | @uri')"
response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT
github_get "repos/$repository/commits/$encoded_ref" "$response_file"

source_sha="$(jq -er 'if type == "object" then .sha else empty end' "$response_file")" ||
  die 'GitHub response did not contain a commit SHA'
validate_sha "$source_sha"
if [[ "$source_ref" =~ ^[0-9a-f]{40}$ ]] && [[ "$source_sha" != "$source_ref" ]]; then
  die 'GitHub resolved an exact requested SHA to a different commit'
fi
printf '%s\n' "$source_sha"
unset GH_TOKEN
