#!/usr/bin/env bash
set -Eeuo pipefail
github_token=${GH_TOKEN:-}
unset GH_TOKEN GITHUB_TOKEN CONFIRM_DISPATCH CONFIRM_MUTATION

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION_REPOSITORY=voiceofhu/one-action
# shellcheck source=scripts/lib/product.sh
source "$PROJECT_ROOT/scripts/lib/product.sh"

[[ "$#" -eq 1 ]] || product_die 'usage: release-web.sh PRODUCT'
load_product "$1"
: "${VERSION:?VERSION is required}"
SOURCE_ROOT=${SOURCE_ROOT:-$(cd -- "$PROJECT_ROOT/.." && pwd)}
web_dir_variable="ONE_$(printf '%s' "$PRODUCT_KEY" | tr '[:lower:]' '[:upper:]')_WEB_DIR"
web_dir=${!web_dir_variable:-$SOURCE_ROOT/$PRODUCT_NAME/web}
web_repository=$PRODUCT_WEB_REPOSITORY

[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  printf '%s\n' 'VERSION must contain three numeric components without leading zeroes' >&2
  exit 1
}

case "${DRY_RUN:-true}" in
  true|1|yes) dry_run=true ;;
  false|0|no) dry_run=false ;;
  *) printf '%s\n' 'DRY_RUN must be true or false' >&2; exit 1 ;;
esac

validate_source_repository() {
  local label=$1 directory=$2 expected_repository=$3 expected_manifest=$4
  local remote branch status

  [[ -d "$directory/.git" && -f "$directory/$expected_manifest" ]] || {
    printf '%s source repository or manifest is missing: %s\n' "$label" "$directory/$expected_manifest" >&2
    exit 1
  }
  remote="$(git -C "$directory" config --get remote.origin.url)"
  case "$remote" in
    "https://github.com/$expected_repository"|"https://github.com/$expected_repository.git"|\
    "git@github.com:$expected_repository"|"git@github.com:$expected_repository.git") ;;
    *) printf '%s origin must be %s, got %s\n' "$label" "$expected_repository" "$remote" >&2; exit 1 ;;
  esac
  branch="$(git -C "$directory" symbolic-ref --quiet --short HEAD)" || {
    printf '%s source repository must be on a branch\n' "$label" >&2
    exit 1
  }
  status="$(git -C "$directory" status --porcelain --untracked-files=all)"
  [[ -z "$status" ]] || {
    printf '%s source repository must be clean:\n%s\n' "$label" "$status" >&2
    exit 1
  }
  printf '%s|%s\n' "$branch" "$(git -C "$directory" rev-parse HEAD)"
}

validate_action_repository() {
  local remote branch status
  remote="$(git -C "$PROJECT_ROOT" config --get remote.origin.url)"
  case "$remote" in
    "https://github.com/$ACTION_REPOSITORY"|"https://github.com/$ACTION_REPOSITORY.git"|\
    "git@github.com:$ACTION_REPOSITORY"|"git@github.com:$ACTION_REPOSITORY.git") ;;
    *) printf 'Action origin must be %s, got %s\n' "$ACTION_REPOSITORY" "$remote" >&2; exit 1 ;;
  esac
  branch="$(git -C "$PROJECT_ROOT" symbolic-ref --quiet --short HEAD)" || true
  [[ "$branch" == main ]] || {
    printf 'Action repository must be on main, got %s\n' "${branch:-detached HEAD}" >&2
    exit 1
  }
  status="$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)"
  [[ -z "$status" ]] || {
    printf 'Action repository must be clean:\n%s\n' "$status" >&2
    exit 1
  }
  git -C "$PROJECT_ROOT" rev-parse --verify HEAD
}

web_state="$(validate_source_repository Web "$web_dir" "$web_repository" package.json)"
web_branch=${web_state%%|*}
web_head=${web_state#*|}
action_head="$(git -C "$PROJECT_ROOT" rev-parse --verify HEAD)"
printf '%s Web: %s at %s, version %s\n' "$PRODUCT_TITLE" "$web_repository" "$web_head" "$VERSION"
if [[ "$dry_run" == true ]]; then
  printf '%s\n' 'DRY_RUN=true: no checks, dispatch, or deployment.'
  exit 0
fi
[[ "$(validate_action_repository)" == "$action_head" ]]
git -C "$PROJECT_ROOT" fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
[[ "$action_head" == "$(git -C "$PROJECT_ROOT" rev-parse origin/main)" ]]
make --no-print-directory -C "$PROJECT_ROOT" "validate-$PRODUCT_KEY-web"
git -C "$web_dir" fetch --no-tags origin "refs/heads/$web_branch:refs/remotes/origin/$web_branch"
[[ "$web_head" == "$(git -C "$web_dir" rev-parse "origin/$web_branch")" ]]
pnpm --dir "$web_dir" install --frozen-lockfile
for gate in "${PRODUCT_WEB_GATES[@]}"; do
  pnpm --dir "$web_dir" "$gate"
done
[[ "$(validate_source_repository Web "$web_dir" "$web_repository" package.json)" == "$web_state" ]]
[[ "$(validate_action_repository)" == "$action_head" ]]
CONFIRM_DISPATCH="dispatch:$PRODUCT_WEB_WORKFLOW:$action_head" \
CONFIRM_MUTATION="mutate:$PRODUCT_WEB_WORKFLOW:$action_head" \
DRY_RUN=false ACTION_REPOSITORY="$ACTION_REPOSITORY" ACTION_REF=main GH_TOKEN="$github_token" \
bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" "$PRODUCT_WEB_WORKFLOW" \
  "web_repository=$web_repository" "web_ref=$web_head" \
  "version=$VERSION" 'publish=true' 'deploy=true'
