#!/usr/bin/env bash
set -Eeuo pipefail
github_token=${GH_TOKEN:-}
unset GH_TOKEN GITHUB_TOKEN CONFIRM_DISPATCH CONFIRM_MUTATION

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION_REPOSITORY=voiceofhu/one-action

: "${VERSION:?VERSION is required}"
: "${ONE_BROWSER_BACKEND_DIR:?ONE_BROWSER_BACKEND_DIR is required}"
: "${ONE_BROWSER_BACKEND_REPOSITORY:?ONE_BROWSER_BACKEND_REPOSITORY is required}"
: "${ONE_BROWSER_WEB_DIR:?ONE_BROWSER_WEB_DIR is required}"
: "${ONE_BROWSER_WEB_REPOSITORY:?ONE_BROWSER_WEB_REPOSITORY is required}"

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

server_state="$(validate_source_repository Server "$ONE_BROWSER_BACKEND_DIR" "$ONE_BROWSER_BACKEND_REPOSITORY" Cargo.toml)"
web_state="$(validate_source_repository Web "$ONE_BROWSER_WEB_DIR" "$ONE_BROWSER_WEB_REPOSITORY" package.json)"
server_branch=${server_state%%|*}
server_head=${server_state#*|}
web_branch=${web_state%%|*}
web_head=${web_state#*|}
action_head="$(git -C "$PROJECT_ROOT" rev-parse --verify HEAD)"

printf '%s\n' \
  'One Browser Server release plan:' \
  "  version:       $VERSION" \
  "  server:        $ONE_BROWSER_BACKEND_REPOSITORY@$server_head" \
  "  web:           $ONE_BROWSER_WEB_REPOSITORY@$web_head" \
  "  server branch: $server_branch" \
  "  web branch:    $web_branch" \
  "  action:        $ACTION_REPOSITORY@$action_head" \
  '  trigger:       workflow_dispatch'

if [[ "$dry_run" == true ]]; then
  printf '%s\n' \
    'DRY_RUN=true: checks, workflow dispatch, image publication, and deployment are unchanged.' \
    'The real run checks the exact published source commits, then dispatches the workflow.'
  exit 0
fi

[[ "$(validate_action_repository)" == "$action_head" ]]
git -C "$PROJECT_ROOT" fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
[[ "$action_head" == "$(git -C "$PROJECT_ROOT" rev-parse refs/remotes/origin/main)" ]] || {
  printf '%s\n' 'Action HEAD must exactly match published origin/main before release.' >&2
  exit 1
}
make --no-print-directory -C "$PROJECT_ROOT" validate-browser-server
[[ "$(validate_action_repository)" == "$action_head" ]] || {
  printf '%s\n' 'Action source changed during local validation.' >&2
  exit 1
}

preflight_source() {
  local label=$1 directory=$2 branch=$3
  git -C "$directory" fetch --no-tags origin "refs/heads/$branch:refs/remotes/origin/$branch"
  [[ "$(git -C "$directory" rev-parse HEAD)" == "$(git -C "$directory" rev-parse "origin/$branch")" ]] || {
    printf '%s HEAD must exactly match published origin/%s before triggering One Action.\n' "$label" "$branch" >&2
    exit 1
  }
}

preflight_source Server "$ONE_BROWSER_BACKEND_DIR" "$server_branch"
preflight_source Web "$ONE_BROWSER_WEB_DIR" "$web_branch"

pnpm --dir "$ONE_BROWSER_WEB_DIR" install --frozen-lockfile
pnpm --dir "$ONE_BROWSER_WEB_DIR" lint
pnpm --dir "$ONE_BROWSER_WEB_DIR" typecheck
pnpm --dir "$ONE_BROWSER_WEB_DIR" test
pnpm --dir "$ONE_BROWSER_WEB_DIR" build
cargo fmt --manifest-path "$ONE_BROWSER_BACKEND_DIR/Cargo.toml" --all --check
cargo clippy --manifest-path "$ONE_BROWSER_BACKEND_DIR/Cargo.toml" --all-targets --all-features --locked -- -D warnings
cargo test --manifest-path "$ONE_BROWSER_BACKEND_DIR/Cargo.toml" --all-features --locked
cargo build --manifest-path "$ONE_BROWSER_BACKEND_DIR/Cargo.toml" --release --locked --bin one-browser-backend

[[ "$(git -C "$ONE_BROWSER_BACKEND_DIR" rev-parse HEAD)" == "$server_head" \
  && -z "$(git -C "$ONE_BROWSER_BACKEND_DIR" status --porcelain --untracked-files=all)" ]] || {
  printf '%s\n' 'Server source changed during local validation.' >&2
  exit 1
}
[[ "$(git -C "$ONE_BROWSER_WEB_DIR" rev-parse HEAD)" == "$web_head" \
  && -z "$(git -C "$ONE_BROWSER_WEB_DIR" status --porcelain --untracked-files=all)" ]] || {
  printf '%s\n' 'Web source changed during local validation.' >&2
  exit 1
}
preflight_source Server "$ONE_BROWSER_BACKEND_DIR" "$server_branch"
preflight_source Web "$ONE_BROWSER_WEB_DIR" "$web_branch"

CONFIRM_DISPATCH="dispatch:browser-server.yml:$action_head" \
CONFIRM_MUTATION="mutate:browser-server.yml:$action_head" \
DRY_RUN=false \
ACTION_REPOSITORY="$ACTION_REPOSITORY" \
ACTION_REF=main \
GH_TOKEN="$github_token" \
bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" browser-server.yml \
  "backend_repository=$ONE_BROWSER_BACKEND_REPOSITORY" \
  "backend_ref=$server_head" \
  "web_repository=$ONE_BROWSER_WEB_REPOSITORY" \
  "web_ref=$web_head" \
  "version=$VERSION" \
  'publish=true' \
  'deploy=true'
printf 'Dispatched One Browser Server image publication and deployment at Action %s.\n' \
  "$action_head"
