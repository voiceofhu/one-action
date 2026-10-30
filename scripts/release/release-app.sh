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

# Sets checkout_sha to the HEAD of DIR once it is the clean root checkout of
# REPOSITORY, on BRANCH and already pushed to origin.
verify_checkout() {
  local label=$1 dir=$2 repository=$3 branch=$4 branch_variable=$5 missing_hint=$6 root
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" ||
    die "$label Git repository is unavailable or incomplete: $dir; $missing_hint"
  [[ "$(cd "$dir" && pwd -P)" == "$(cd "$root" && pwd -P)" ]] ||
    die "$label directory must be the $label repository root: $dir"
  checkout_sha="$(git -C "$dir" rev-parse --verify HEAD)"
  [[ "$checkout_sha" == "$(git -C "$dir" rev-parse --verify "${branch}^{commit}")" ]] ||
    die "$label HEAD must match $branch_variable ($branch) before validation"
  is_github_remote "$(origin_remote_url "$dir")" "$repository" ||
    die "$label origin differs from the configured source repository"
  [[ -z "$(git -C "$dir" status --porcelain --untracked-files=all)" ]] ||
    die "$label worktree must be clean before release validation"
  git -C "$dir" fetch --no-tags origin "+refs/heads/$branch:refs/remotes/origin/$branch"
  git -C "$dir" merge-base --is-ancestor "$checkout_sha" "refs/remotes/origin/$branch" ||
    die "$label HEAD is not pushed to origin/$branch"
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
# A bundled web is read from ../web, the layout CI checks out as well.
web_dir="$(dirname -- "$app_dir")/web"
web_ref_variable="${app_env_prefix}_WEB_REF"
web_ref=${!web_ref_variable:-main}
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die 'Invalid App version'
for ref_variable in "$app_ref_variable" "$web_ref_variable"; do
  ref=${!ref_variable:-main}
  [[ "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$ && "$ref" != *..* ]] ||
    die "$ref_variable must be a branch name"
done
require_tool git

printf '%s release: %s-v%s from %s branch %s (tag deploy/%s-app/%s)\n' \
  "$APP_TITLE" "$APP_RELEASE_PREFIX" "$VERSION" "$APP_REPOSITORY" "$app_ref" "$APP_KEY" "$VERSION" >&2
[[ -z "$APP_WEB_REPOSITORY" ]] ||
  printf 'Bundled web: %s branch %s from %s (pinned as web_ref)\n' \
    "$APP_WEB_REPOSITORY" "$web_ref" "$web_dir" >&2
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
[[ -z "$APP_GO_VERSION_FILE" ]] || require_tool go
verify_checkout App "$app_dir" "$APP_REPOSITORY" "$app_ref" "$app_ref_variable" \
  "restore its Git metadata or set $app_dir_variable to a valid App checkout"
app_sha=$checkout_sha
pins=("app_ref=$app_sha")
if [[ -n "$APP_WEB_REPOSITORY" ]]; then
  verify_checkout Web "$web_dir" "$APP_WEB_REPOSITORY" "$web_ref" "$web_ref_variable" \
    'the App bundles the web checked out next to it as ../web'
  web_sha=$checkout_sha
  pins+=("web_ref=$web_sha")
fi
[[ -f "$app_dir/scripts/update-version.mjs" ]] ||
  die 'App source must provide scripts/update-version.mjs for CI release version stamping'

printf 'Validating %s before tagging...\n' "$APP_TITLE"
pnpm --dir "$app_dir" install --frozen-lockfile
[[ -z "$APP_WEB_REPOSITORY" ]] || pnpm --dir "$web_dir" install --frozen-lockfile
for script in "$app_dir"/scripts/*.mjs; do
  node --check "$script"
done
if compgen -G "$app_dir/scripts/tests/*.test.mjs" >/dev/null; then
  node --test "$app_dir"/scripts/tests/*.test.mjs
fi
if [[ -n "$APP_GO_VERSION_FILE" ]]; then
  (cd -- "$(dirname -- "$app_dir/$APP_GO_VERSION_FILE")" && go vet ./... && go test -count=1 ./...)
fi
# The bundle inputs Tauri's beforeBuildCommand prepares in CI (web copy, sidecars),
# which the Rust build checks for.
if [[ -f "$app_dir/scripts/prepare-bundle.mjs" ]]; then
  node "$app_dir/scripts/prepare-bundle.mjs"
fi
cargo fmt --manifest-path "$app_dir/src-tauri/Cargo.toml" --all --check
cargo clippy --manifest-path "$app_dir/src-tauri/Cargo.toml" \
  --all-targets --all-features --locked -- -D warnings
cargo test --manifest-path "$app_dir/src-tauri/Cargo.toml" \
  --all-features --locked

[[ "$app_sha" == "$(git -C "$app_dir" rev-parse HEAD)" \
  && -z "$(git -C "$app_dir" status --porcelain --untracked-files=all)" ]] ||
  die 'App source changed during local validation'
if [[ -n "$APP_WEB_REPOSITORY" ]]; then
  [[ "$web_sha" == "$(git -C "$web_dir" rev-parse HEAD)" \
    && -z "$(git -C "$web_dir" status --porcelain --untracked-files=all)" ]] ||
    die 'Web source changed during local validation'
fi
[[ "$action_sha" == "$(git -C "$PROJECT_ROOT" rev-parse HEAD)" ]] ||
  die 'Action HEAD changed during local validation'

DRY_RUN=false bash "$PROJECT_ROOT/scripts/release/trigger.sh" \
  "$APP_WORKFLOW" "$action_sha" "$VERSION" "${pins[@]}"
