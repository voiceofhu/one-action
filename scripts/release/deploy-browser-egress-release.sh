#!/usr/bin/env bash
set -Eeuo pipefail
github_token=${GH_TOKEN:-}
unset GH_TOKEN GITHUB_TOKEN CONFIRM_DISPATCH CONFIRM_MUTATION

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION_REPOSITORY=voiceofhu/one-action
: "${VERSION:?VERSION is required}"
: "${ONE_BROWSER_EGRESS_DIR:?ONE_BROWSER_EGRESS_DIR is required}"
: "${ONE_BROWSER_EGRESS_REPOSITORY:?ONE_BROWSER_EGRESS_REPOSITORY is required}"

[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  printf '%s\n' 'VERSION must contain three numeric components without leading zeroes' >&2
  exit 1
}

release_tag="one-browser-egress-v$VERSION"
printf '%s\n' \
  'One Browser Egress release plan:' \
  "  version:    $VERSION" \
  "  source:     $ONE_BROWSER_EGRESS_REPOSITORY" \
  '  source ref: exact checked-out branch commit' \
  "  release:    $release_tag" \
  "  image:      ghcr.io/voiceofhu/one-browser-egress:$VERSION"

case "${DRY_RUN:-true}" in
  true|1|yes)
    printf '%s\n' 'DRY_RUN=true: Git refs, image, Release, and workflow state are unchanged.'
    exit 0
    ;;
  false|0|no) ;;
  *) printf '%s\n' 'DRY_RUN must be true or false' >&2; exit 1 ;;
esac

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

[[ -d "$ONE_BROWSER_EGRESS_DIR/.git" && -f "$ONE_BROWSER_EGRESS_DIR/Cargo.toml" ]] || {
  printf 'One Browser Egress repository is missing: %s\n' "$ONE_BROWSER_EGRESS_DIR" >&2
  exit 1
}

action_head="$(validate_action_repository)"
git -C "$PROJECT_ROOT" fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
[[ "$action_head" == "$(git -C "$PROJECT_ROOT" rev-parse refs/remotes/origin/main)" ]] || {
  printf '%s\n' 'Action HEAD must exactly match published origin/main before release.' >&2
  exit 1
}
make --no-print-directory -C "$PROJECT_ROOT" validate-browser-egress

remote="$(git -C "$ONE_BROWSER_EGRESS_DIR" config --get remote.origin.url)"
case "$remote" in
  "https://github.com/$ONE_BROWSER_EGRESS_REPOSITORY"|"https://github.com/$ONE_BROWSER_EGRESS_REPOSITORY.git"|\
  "git@github.com:$ONE_BROWSER_EGRESS_REPOSITORY"|"git@github.com:$ONE_BROWSER_EGRESS_REPOSITORY.git") ;;
  *) printf 'One Browser Egress origin must be %s, got %s\n' \
       "$ONE_BROWSER_EGRESS_REPOSITORY" "$remote" >&2; exit 1 ;;
esac

[[ -z "$(git -C "$ONE_BROWSER_EGRESS_DIR" status --porcelain --untracked-files=all)" ]] || {
  printf 'One Browser Egress worktree must be clean: %s\n' "$ONE_BROWSER_EGRESS_DIR" >&2
  exit 1
}
branch="$(git -C "$ONE_BROWSER_EGRESS_DIR" symbolic-ref --quiet --short HEAD)" || {
  printf '%s\n' 'One Browser Egress repository must be on a branch' >&2
  exit 1
}
git -C "$ONE_BROWSER_EGRESS_DIR" fetch --no-tags origin \
  "refs/heads/$branch:refs/remotes/origin/$branch"
egress_ref="$(git -C "$ONE_BROWSER_EGRESS_DIR" rev-parse HEAD)"
[[ "$egress_ref" == "$(git -C "$ONE_BROWSER_EGRESS_DIR" rev-parse "origin/$branch")" ]] || {
  printf 'One Browser Egress branch must exactly match origin/%s before release.\n' "$branch" >&2
  exit 1
}

cargo fmt --manifest-path "$ONE_BROWSER_EGRESS_DIR/Cargo.toml" --all --check
cargo clippy --manifest-path "$ONE_BROWSER_EGRESS_DIR/Cargo.toml" \
  --all-targets --all-features --locked -- -D warnings
cargo test --manifest-path "$ONE_BROWSER_EGRESS_DIR/Cargo.toml" \
  --all-features --locked

[[ "$(git -C "$ONE_BROWSER_EGRESS_DIR" rev-parse HEAD)" == "$egress_ref" \
  && -z "$(git -C "$ONE_BROWSER_EGRESS_DIR" status --porcelain --untracked-files=all)" ]] || {
  printf '%s\n' 'One Browser Egress source changed during local validation.' >&2
  exit 1
}
[[ "$egress_ref" =~ ^[0-9a-f]{40}$ ]] || {
  printf '%s\n' 'Resolved Egress release source is not an exact commit SHA.' >&2
  exit 1
}

CONFIRM_DISPATCH="dispatch:egress.yml:$action_head" \
CONFIRM_MUTATION="mutate:egress.yml:$action_head" \
DRY_RUN=false \
ACTION_REPOSITORY="$ACTION_REPOSITORY" \
ACTION_REF=main \
GH_TOKEN="$github_token" \
bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" egress.yml \
  "egress_repository=$ONE_BROWSER_EGRESS_REPOSITORY" \
  "egress_ref=$egress_ref" \
  "version=$VERSION" \
  'environment=prod' \
  'publish=true' \
  'deploy=false'
printf 'Triggered One Browser Egress image and Release workflow for %s at Action %s\n' \
  "$release_tag" "$action_head"
