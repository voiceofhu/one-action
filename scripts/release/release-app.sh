#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/git-remote.sh
source "$PROJECT_ROOT/scripts/lib/git-remote.sh"
# shellcheck source=scripts/lib/app.sh
source "$PROJECT_ROOT/scripts/lib/app.sh"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

[[ "$#" -eq 1 ]] || die 'usage: release-app.sh APP'
load_app "$1"
: "${VERSION:?VERSION is required}"
SOURCE_ROOT=${SOURCE_ROOT:-$(cd -- "$PROJECT_ROOT/.." && pwd)}
app_env_prefix="ONE_$(printf '%s' "$APP_KEY" | tr '[:lower:]' '[:upper:]')_APP"
app_dir_variable="${app_env_prefix}_DIR"
app_ref_variable="${app_env_prefix}_REF"
app_dir=${!app_dir_variable:-$SOURCE_ROOT/$APP_SOURCE_DIR}
app_ref=${!app_ref_variable:-main}
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die 'Invalid App version'
[[ "$app_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$ && "$app_ref" != *..* ]] ||
  die "$app_ref_variable must be a branch name"
require_tool git

printf '%s release: %s-v%s from %s branch %s (tag deploy/%s-app/%s)\n' \
  "$APP_TITLE" "$APP_RELEASE_PREFIX" "$VERSION" "$APP_REPOSITORY" "$app_ref" "$APP_KEY" "$VERSION" >&2
case "${DRY_RUN:-true}" in
  true|1|yes)
    printf '%s\n' 'DRY_RUN=true: no checks ran and no deploy tag was pushed.'
    exit 0
    ;;
  false|0|no) ;;
  *) die 'DRY_RUN must be true or false' ;;
esac

action_origin="$(origin_remote_url "$PROJECT_ROOT")"
is_github_remote "$action_origin" voiceofhu/one-action ||
  die "Action origin must be voiceofhu/one-action, got $action_origin"
[[ -z "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)" ]] ||
  die 'Action repository must be clean'
action_sha="$(git -C "$PROJECT_ROOT" rev-parse --verify HEAD)"
git -C "$PROJECT_ROOT" fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
[[ "$action_sha" == "$(git -C "$PROJECT_ROOT" rev-parse refs/remotes/origin/main)" ]] ||
  die 'Action HEAD must exactly match published origin/main'

require_tool pnpm
require_tool node
require_tool cargo
app_root="$(git -C "$app_dir" rev-parse --show-toplevel 2>/dev/null)" ||
  die "App Git repository is unavailable or incomplete: $app_dir; restore its Git metadata or set $app_dir_variable to a valid App checkout"
[[ "$(cd "$app_dir" && pwd -P)" == "$(cd "$app_root" && pwd -P)" ]] ||
  die "$app_dir_variable must point to the App repository root: $app_dir"
app_sha="$(git -C "$app_dir" rev-parse --verify HEAD)"
[[ "$app_sha" == "$(git -C "$app_dir" rev-parse --verify "${app_ref}^{commit}")" ]] ||
  die "App HEAD must match $app_ref_variable ($app_ref) before validation"
app_origin="$(origin_remote_url "$app_dir")"
is_github_remote "$app_origin" "$APP_REPOSITORY" ||
  die 'App origin differs from the configured source repository'
[[ -z "$(git -C "$app_dir" status --porcelain --untracked-files=all)" ]] ||
  die 'App worktree must be clean before release validation'
git -C "$app_dir" fetch --no-tags origin "+refs/heads/$app_ref:refs/remotes/origin/$app_ref"
git -C "$app_dir" merge-base --is-ancestor "$app_sha" "refs/remotes/origin/$app_ref" ||
  die "App HEAD is not pushed to origin/$app_ref"
[[ -f "$app_dir/scripts/update-version.mjs" ]] ||
  die 'App source must provide scripts/update-version.mjs for CI release version stamping'

printf 'Validating %s before tagging...\n' "$APP_TITLE"
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
[[ "$action_sha" == "$(git -C "$PROJECT_ROOT" rev-parse HEAD)" ]] ||
  die 'Action HEAD changed during local validation'

DRY_RUN=false bash "$PROJECT_ROOT/scripts/release/trigger.sh" \
  "$APP_WORKFLOW" "$action_sha" "$VERSION" "app_ref=$app_sha"
