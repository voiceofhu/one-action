#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
github_token=${GH_TOKEN:-}
unset GH_TOKEN GITHUB_TOKEN CONFIRM_DISPATCH CONFIRM_MUTATION

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PROJECT_ROOT/scripts/github/common.sh"
# shellcheck source=scripts/lib/app.sh
source "$PROJECT_ROOT/scripts/lib/app.sh"

[[ "$#" -eq 1 ]] || die 'usage: release-app.sh APP'
load_app "$1"
ACTION_REF=${ACTION_REF:-main}
: "${VERSION:?VERSION is required}"
SOURCE_ROOT=${SOURCE_ROOT:-$(cd -- "$PROJECT_ROOT/.." && pwd)}
app_env_prefix="ONE_$(printf '%s' "$APP_KEY" | tr '[:lower:]' '[:upper:]')_APP"
app_dir_variable="${app_env_prefix}_DIR"
app_ref_variable="${app_env_prefix}_REF"
app_dir=${!app_dir_variable:-$SOURCE_ROOT/$APP_SOURCE_DIR}
app_ref=${!app_ref_variable:-main}
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die 'Invalid App version'
validate_ref "$ACTION_REF"
validate_ref "$app_ref"
require_tool git
action_sha="$(git -C "$PROJECT_ROOT" rev-parse --verify "${ACTION_REF}^{commit}")"
validate_sha "$action_sha"
require_tool jq

printf '%s release: %s-v%s (tag created on One Action by CI)\n' "$APP_TITLE" "$APP_RELEASE_PREFIX" "$VERSION" >&2

payload="$(jq -cn --arg ref "$ACTION_REF" --arg action_sha "$action_sha" \
  --arg repository "$APP_REPOSITORY" --arg confirmation "$APP_CONFIRMATION" \
  --arg source_ref "$app_ref" --arg version "$VERSION" \
  '{ref: $ref, inputs: {expected_action_sha: $action_sha, confirmation: ("enable:" + $confirmation + ":" + $action_sha), app_repository: $repository, app_ref: $source_ref, version: $version, publish: true}}')"
case "${DRY_RUN:-true}" in
  true|1|yes)
    jq . <<<"$payload"
    printf '%s\n' 'DRY_RUN=true: no workflow was dispatched.'
    exit 0
    ;;
  false|0|no) ;;
  *) die 'DRY_RUN must be true or false' ;;
esac

require_tool pnpm
require_tool node
require_tool cargo
app_root="$(git -C "$app_dir" rev-parse --show-toplevel 2>/dev/null)" ||
  die "App Git repository is unavailable or incomplete: $app_dir; restore its Git metadata or set $app_dir_variable to a valid App checkout"
[[ "$(cd "$app_dir" && pwd -P)" == "$(cd "$app_root" && pwd -P)" ]] ||
  die "$app_dir_variable must point to the App repository root: $app_dir"
app_sha="$(git -C "$app_dir" rev-parse --verify HEAD)"
validate_sha "$app_sha"
[[ "$app_sha" == "$(git -C "$app_dir" rev-parse --verify "${app_ref}^{commit}")" ]] ||
  die "App HEAD must match $app_ref_variable ($app_ref) before validation"
app_origin="$(git -C "$app_dir" config --get remote.origin.url)"
case "$app_origin" in
  "https://github.com/$APP_REPOSITORY"|"https://github.com/$APP_REPOSITORY.git"|\
  "git@github.com:$APP_REPOSITORY"|"git@github.com:$APP_REPOSITORY.git") ;;
  *) die 'App origin differs from the configured source repository' ;;
esac
[[ -z "$(git -C "$app_dir" status --porcelain --untracked-files=all)" ]] ||
  die 'App worktree must be clean before release validation'
[[ -f "$app_dir/scripts/update-version.mjs" ]] ||
  die 'App source must provide scripts/update-version.mjs for CI release version stamping'

printf 'Validating %s before dispatch...\n' "$APP_TITLE"
pnpm --dir "$app_dir" install --frozen-lockfile
for script in "$app_dir"/scripts/*.mjs; do
  node --check "$script"
done
if compgen -G "$app_dir/scripts/tests/*.test.mjs" >/dev/null; then
  node --test "$app_dir"/scripts/tests/*.test.mjs
fi
cargo fmt --manifest-path "$app_dir/src-tauri/Cargo.toml" --all --check
cargo clippy --manifest-path "$app_dir/src-tauri/Cargo.toml" \
  --all-targets --all-features --locked -- -D warnings
cargo test --manifest-path "$app_dir/src-tauri/Cargo.toml" \
  --all-features --locked

[[ "$app_sha" == "$(git -C "$app_dir" rev-parse HEAD)" \
  && -z "$(git -C "$app_dir" status --porcelain --untracked-files=all)" ]] ||
  die 'App source changed during local validation'
payload="$(jq -c --arg app_sha "$app_sha" '.inputs.app_ref = $app_sha' <<<"$payload")"

require_tool curl
GH_TOKEN="$github_token"
normalize_github_token
payload_file="$(mktemp)"
response_file="$(mktemp)"
trap 'rm -f "$payload_file" "$response_file"' EXIT
printf '%s' "$payload" >"$payload_file"
github_post "repos/$FIXED_ACTION_REPOSITORY/actions/workflows/$APP_WORKFLOW/dispatches" \
  "$payload_file" "$response_file"
unset GH_TOKEN
printf 'Dispatched %s at %s; the workflow will resolve and build App source.\n' "$APP_WORKFLOW" "$ACTION_REF"
