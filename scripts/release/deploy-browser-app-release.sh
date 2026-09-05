#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
github_token=${GH_TOKEN:-}
unset GH_TOKEN GITHUB_TOKEN CONFIRM_DISPATCH CONFIRM_MUTATION

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PROJECT_ROOT/scripts/github/common.sh"

ACTION_REF=${ACTION_REF:-main}
: "${VERSION:?VERSION is required}"
: "${ONE_BROWSER_APP_REPOSITORY:?ONE_BROWSER_APP_REPOSITORY is required}"
: "${ONE_BROWSER_APP_REF:?ONE_BROWSER_APP_REF is required}"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die 'Invalid App version'
[[ "$ONE_BROWSER_APP_REPOSITORY" == voiceofhu/one-browser-app ]] || die 'Invalid App repository'
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

: "${ONE_BROWSER_APP_DIR:?ONE_BROWSER_APP_DIR is required}"
require_tool pnpm
require_tool node
require_tool cargo
app_sha="$(git -C "$ONE_BROWSER_APP_DIR" rev-parse --verify HEAD)"
validate_sha "$app_sha"
[[ "$app_sha" == "$(git -C "$ONE_BROWSER_APP_DIR" rev-parse --verify "${ONE_BROWSER_APP_REF}^{commit}")" ]] ||
  die 'App HEAD must match ONE_BROWSER_APP_REF before validation'
app_origin="$(git -C "$ONE_BROWSER_APP_DIR" config --get remote.origin.url)"
case "$app_origin" in
  "https://github.com/$ONE_BROWSER_APP_REPOSITORY"|"https://github.com/$ONE_BROWSER_APP_REPOSITORY.git"|\
  "git@github.com:$ONE_BROWSER_APP_REPOSITORY"|"git@github.com:$ONE_BROWSER_APP_REPOSITORY.git") ;;
  *) die 'App origin differs from the configured source repository' ;;
esac
[[ -z "$(git -C "$ONE_BROWSER_APP_DIR" status --porcelain --untracked-files=all)" ]] ||
  die 'App worktree must be clean before release validation'
[[ "$(node -p 'require(process.argv[1]).version' "$ONE_BROWSER_APP_DIR/package.json")" == "$VERSION" ]] ||
  die 'App package version differs from release version'

printf '%s\n' 'Validating One Browser App before dispatch...'
pnpm --dir "$ONE_BROWSER_APP_DIR" install --frozen-lockfile
for script in "$ONE_BROWSER_APP_DIR"/scripts/*.mjs; do
  node --check "$script"
done
cargo fmt --manifest-path "$ONE_BROWSER_APP_DIR/src-tauri/Cargo.toml" --all --check
cargo clippy --manifest-path "$ONE_BROWSER_APP_DIR/src-tauri/Cargo.toml" \
  --all-targets --all-features --locked -- -D warnings
cargo test --manifest-path "$ONE_BROWSER_APP_DIR/src-tauri/Cargo.toml" \
  --all-features --locked

[[ "$app_sha" == "$(git -C "$ONE_BROWSER_APP_DIR" rev-parse HEAD)" \
  && -z "$(git -C "$ONE_BROWSER_APP_DIR" status --porcelain --untracked-files=all)" ]] ||
  die 'App source changed during local validation'
payload="$(jq -c --arg app_sha "$app_sha" '.inputs.app_ref = $app_sha' <<<"$payload")"

require_tool curl
GH_TOKEN="$github_token"
normalize_github_token
payload_file="$(mktemp)"
response_file="$(mktemp)"
trap 'rm -f "$payload_file" "$response_file"' EXIT
printf '%s' "$payload" >"$payload_file"
github_post "repos/$FIXED_ACTION_REPOSITORY/actions/workflows/app.yml/dispatches" \
  "$payload_file" "$response_file"
unset GH_TOKEN
printf 'Dispatched app.yml at %s; the workflow will resolve and build App source.\n' "$ACTION_REF"
