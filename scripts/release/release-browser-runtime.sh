#!/usr/bin/env bash
# Local entry for the One Browser Chromium runtime. Chromium cannot be built on
# Actions: the chromium repository's `make release` packages it locally,
# uploads the packages to the private staging release runtime-v<VERSION> of
# voiceofhu/one-browser-chromium, then calls this script (through
# `make deploy-browser-runtime`) to push deploy/browser-runtime/<VERSION>
# pinning chromium_ref. browser-runtime.yml verifies the staged packages and
# republishes them as the public One Action Release one-browser-runtime-v<VERSION>.
#
#   VERSION=<v> CHROMIUM_REF=<40-hex sha> [DRY_RUN=true] release-browser-runtime.sh
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/git-remote.sh
source "$PROJECT_ROOT/scripts/lib/git-remote.sh"
ACTION_REPOSITORY=voiceofhu/one-action
CHROMIUM_REPOSITORY=voiceofhu/one-browser-chromium

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" -eq 0 ]] || die 'usage: VERSION=<v> CHROMIUM_REF=<sha> release-browser-runtime.sh'
[[ -n "${VERSION:-}" ]] ||
  die 'VERSION is required: the staging release runtime-v<VERSION> to publish'
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  die 'VERSION must contain three numeric components without leading zeroes'
[[ "${CHROMIUM_REF:-}" =~ ^[0-9a-f]{40}$ ]] ||
  die "CHROMIUM_REF must be the exact 40-hex $CHROMIUM_REPOSITORY main commit"

printf '%s\n' \
  'One Browser Runtime release plan:' \
  "  version:  $VERSION" \
  "  staging:  $CHROMIUM_REPOSITORY@runtime-v$VERSION" \
  "  source:   $CHROMIUM_REPOSITORY@$CHROMIUM_REF" \
  "  release:  $ACTION_REPOSITORY@one-browser-runtime-v$VERSION" \
  "  trigger:  deploy/browser-runtime/$VERSION"

case "${DRY_RUN:-true}" in
  true|1|yes)
    printf '%s\n' 'DRY_RUN=true: no checks ran and no deploy tag was pushed.'
    exit 0
    ;;
  false|0|no) ;;
  *) die 'DRY_RUN must be true or false' ;;
esac

action_origin="$(origin_remote_url "$PROJECT_ROOT")"
is_github_remote "$action_origin" "$ACTION_REPOSITORY" ||
  die "Action origin must be $ACTION_REPOSITORY, got $action_origin"
branch="$(git -C "$PROJECT_ROOT" symbolic-ref --quiet --short HEAD)" || true
[[ "$branch" == main ]] || die "Action repository must be on main, got ${branch:-detached HEAD}"
[[ -z "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)" ]] ||
  die 'Action repository must be clean'
action_sha="$(git -C "$PROJECT_ROOT" rev-parse --verify HEAD)"
git -C "$PROJECT_ROOT" fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
[[ "$action_sha" == "$(git -C "$PROJECT_ROOT" rev-parse refs/remotes/origin/main)" ]] ||
  die 'Action HEAD must exactly match published origin/main'

make --no-print-directory -C "$PROJECT_ROOT" validate-browser-runtime
[[ "$action_sha" == "$(git -C "$PROJECT_ROOT" rev-parse HEAD)" ]] ||
  die 'Action HEAD changed during local validation'

DRY_RUN=false bash "$PROJECT_ROOT/scripts/release/trigger.sh" \
  browser-runtime.yml "$action_sha" "$VERSION" "chromium_ref=$CHROMIUM_REF"
printf 'Triggered One Browser Runtime Release one-browser-runtime-v%s at Action %s\n' \
  "$VERSION" "$action_sha"
