#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PROJECT_ROOT/scripts/github/common.sh"

ACTION_REF=${ACTION_REF:-main}
: "${VERSION:?VERSION is required}"
: "${ONE_BROWSER_APP_REPOSITORY:?ONE_BROWSER_APP_REPOSITORY is required}"
: "${ONE_BROWSER_APP_REF:?ONE_BROWSER_APP_REF is required}"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die 'Invalid App version'
[[ "$ONE_BROWSER_APP_REPOSITORY" == voiceofhu/one-browser-app-next ]] || die 'Invalid App repository'
validate_ref "$ACTION_REF"
validate_ref "$ONE_BROWSER_APP_REF"
require_tool git
action_sha="$(git -C "$PROJECT_ROOT" rev-parse --verify "${ACTION_REF}^{commit}")"
validate_sha "$action_sha"
require_tool jq

payload="$(jq -cn --arg ref "$ACTION_REF" --arg action_sha "$action_sha" \
  --arg repository "$ONE_BROWSER_APP_REPOSITORY" \
  --arg source_ref "$ONE_BROWSER_APP_REF" --arg version "$VERSION" \
  '{ref: $ref, inputs: {expected_action_sha: $action_sha, confirmation: ("enable:app:" + $action_sha), app_repository: $repository, app_ref: $source_ref, version: $version, publish: true}}')"
case "${DRY_RUN:-true}" in
  true|1|yes)
    jq . <<<"$payload"
    printf '%s\n' 'DRY_RUN=true: no workflow was dispatched.'
    exit 0
    ;;
  false|0|no) ;;
  *) die 'DRY_RUN must be true or false' ;;
esac

require_tool curl
normalize_github_token
payload_file="$(mktemp)"
response_file="$(mktemp)"
trap 'rm -f "$payload_file" "$response_file"' EXIT
printf '%s' "$payload" >"$payload_file"
github_post "repos/$FIXED_ACTION_REPOSITORY/actions/workflows/app.yml/dispatches" \
  "$payload_file" "$response_file"
unset GH_TOKEN
printf 'Dispatched app.yml at %s; the workflow will resolve and build App source.\n' "$ACTION_REF"
