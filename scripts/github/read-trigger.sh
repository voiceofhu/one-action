#!/usr/bin/env bash
# Reads the deploy/<name>/<version> tag that triggered this workflow run (pushed
# by scripts/release/trigger.sh) and prints `version=…` plus the pinned
# `<key>=<sha>` lines for $GITHUB_OUTPUT. Run inside a full-history checkout of
# One Action at $GITHUB_SHA.
#
#   read-trigger.sh NAME KEY_ref...
set -Eeuo pipefail

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" -ge 2 ]] || die 'usage: read-trigger.sh NAME KEY_ref...'
name=$1
shift
[[ "$name" =~ ^[a-z][a-z0-9]*-(server|web|app|runtime|egress)$ ]] || die "invalid workflow name: $name"

[[ "${GITHUB_REPOSITORY:-}" == voiceofhu/one-action \
  && "${GITHUB_REF_TYPE:-}" == tag \
  && "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] ||
  die 'this workflow only runs from a deploy tag pushed to voiceofhu/one-action'
tag_ref=${GITHUB_REF:-}
[[ "$tag_ref" =~ ^refs/tags/deploy/$name/((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$ ]] ||
  die "trigger ref must be refs/tags/deploy/$name/<version>, got: $tag_ref"
version=${BASH_REMATCH[1]}

# actions/checkout may store the triggering tag as a lightweight ref; fetch the
# annotated object itself, and main to prove the tagged commit was released.
git fetch --quiet --no-tags --force origin \
  "+$tag_ref:$tag_ref" '+refs/heads/main:refs/remotes/origin/main'
[[ "$(git cat-file -t "$tag_ref")" == tag ]] || die "$tag_ref is not an annotated tag"
[[ "$(git rev-parse "$tag_ref^{commit}")" == "$GITHUB_SHA" ]] ||
  die "$tag_ref does not point at the workflow commit"
git merge-base --is-ancestor "$GITHUB_SHA" refs/remotes/origin/main ||
  die 'the tagged Action commit is not on main'

declare -a keys=("$@") values=()
for key in "${keys[@]}"; do
  [[ "$key" =~ ^[a-z][a-z0-9]*_ref$ ]] || die "invalid source key: $key"
  values+=('')
done

# Tag message: everything after the header's blank line, minus any signature.
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  [[ "$line" =~ ^([a-z][a-z0-9]*_ref)=([0-9a-f]{40})$ ]] || die "malformed tag line: $line"
  found=false
  for index in "${!keys[@]}"; do
    [[ "${keys[$index]}" == "${BASH_REMATCH[1]}" ]] || continue
    [[ -z "${values[$index]}" ]] || die "duplicate source pin: ${BASH_REMATCH[1]}"
    values[index]=${BASH_REMATCH[2]}
    found=true
  done
  [[ "$found" == true ]] || die "unexpected source pin: ${BASH_REMATCH[1]}"
done < <(git cat-file tag "$tag_ref" | sed '1,/^$/d' | sed '/^-----BEGIN /,$d')

printf 'version=%s\n' "$version"
for index in "${!keys[@]}"; do
  [[ -n "${values[$index]}" ]] || die "tag does not pin ${keys[$index]}"
  printf '%s=%s\n' "${keys[$index]}" "${values[$index]}"
done
