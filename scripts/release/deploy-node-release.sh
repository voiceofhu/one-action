#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/git-remote.sh
source "$PROJECT_ROOT/scripts/lib/git-remote.sh"
ACTION_REPOSITORY=voiceofhu/one-action
: "${VERSION:?VERSION is required}"
: "${ONE_NODE_DIR:?ONE_NODE_DIR is required}"
: "${ONE_NODE_REPOSITORY:?ONE_NODE_REPOSITORY is required}"

[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  printf '%s\n' 'VERSION must contain three numeric components without leading zeroes' >&2
  exit 1
}
[[ -d "$ONE_NODE_DIR/.git" && -f "$ONE_NODE_DIR/VERSION" ]] || {
  printf 'One Node repository is missing: %s\n' "$ONE_NODE_DIR" >&2
  exit 1
}

release_tag="one-node-v$VERSION"
printf '%s\n' \
  'One Node release plan:' \
  "  version:    $VERSION" \
  "  source:     $ONE_NODE_REPOSITORY" \
  '  source ref: exact main commit' \
  "  release:    $release_tag" \
  "  image:      ghcr.io/voiceofhu/one-node:$VERSION"

case "${DRY_RUN:-true}" in
  true|1|yes)
    printf '%s\n' 'DRY_RUN=true: VERSION, Git refs, image, Release, and workflow state are unchanged.'
    exit 0
    ;;
  false|0|no) ;;
  *) printf '%s\n' 'DRY_RUN must be true or false' >&2; exit 1 ;;
esac

validate_action_repository() {
  local remote branch status
  remote="$(origin_remote_url "$PROJECT_ROOT")"
  is_github_remote "$remote" "$ACTION_REPOSITORY" || {
    printf 'Action origin must be %s, got %s\n' "$ACTION_REPOSITORY" "$remote" >&2
    exit 1
  }
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

action_head="$(validate_action_repository)"
git -C "$PROJECT_ROOT" fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
[[ "$action_head" == "$(git -C "$PROJECT_ROOT" rev-parse refs/remotes/origin/main)" ]] || {
  printf '%s\n' 'Action HEAD must exactly match published origin/main before release.' >&2
  exit 1
}
make --no-print-directory -C "$PROJECT_ROOT" validate-node-runtime
remote="$(origin_remote_url "$ONE_NODE_DIR")"
is_github_remote "$remote" "$ONE_NODE_REPOSITORY" || {
  printf 'One Node origin must be %s, got %s\n' "$ONE_NODE_REPOSITORY" "$remote" >&2
  exit 1
}

[[ -z "$(git -C "$ONE_NODE_DIR" status --porcelain --untracked-files=all)" ]] || {
  printf 'One Node worktree must be clean: %s\n' "$ONE_NODE_DIR" >&2
  exit 1
}
branch="$(git -C "$ONE_NODE_DIR" symbolic-ref --quiet --short HEAD)" || {
  printf '%s\n' 'One Node repository must be on a branch' >&2
  exit 1
}
git -C "$ONE_NODE_DIR" fetch --no-tags origin \
  "refs/heads/$branch:refs/remotes/origin/$branch"
node_ref="$(git -C "$ONE_NODE_DIR" rev-parse HEAD)"
[[ "$node_ref" == "$(git -C "$ONE_NODE_DIR" rev-parse "origin/$branch")" ]] || {
  printf 'One Node branch must exactly match origin/%s before release.\n' "$branch" >&2
  exit 1
}

upstream_version="$(tr -d '\r\n' <"$ONE_NODE_DIR/one/version/UPSTREAM_VERSION")"
upstream_commit="$(tr -d '\r\n' <"$ONE_NODE_DIR/one/version/UPSTREAM_COMMIT")"
make --no-print-directory -C "$ONE_NODE_DIR" verify-upgrade \
  ONE_NODE_VERSION="$VERSION" \
  ONE_NODE_COMMIT="$node_ref" \
  ONE_NODE_UPSTREAM_VERSION="$upstream_version" \
  ONE_NODE_UPSTREAM_COMMIT="$upstream_commit"

[[ "$(git -C "$ONE_NODE_DIR" rev-parse HEAD)" == "$node_ref" \
  && -z "$(git -C "$ONE_NODE_DIR" status --porcelain --untracked-files=all)" ]] || {
  printf '%s\n' 'One Node source changed during local validation.' >&2
  exit 1
}

[[ "$node_ref" =~ ^[0-9a-f]{40}$ ]] || {
  printf '%s\n' 'Resolved Node release source is not an exact commit SHA.' >&2
  exit 1
}

DRY_RUN=false bash "$PROJECT_ROOT/scripts/release/trigger.sh" \
  node-runtime.yml "$action_head" "$VERSION" "node_ref=$node_ref"
printf 'Triggered One Node image and Release workflow for %s at Action %s\n' \
  "$release_tag" "$action_head"
