#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
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

source_tag="v$VERSION"
release_tag="one-node-v$VERSION"
printf '%s\n' \
  'One Node release plan:' \
  "  version:    $VERSION" \
  "  source:     $ONE_NODE_REPOSITORY" \
  "  source tag: $source_tag" \
  "  release:    $release_tag" \
  '  image:      ghcr.io/voiceofhu/one-node:<version>'

case "${DRY_RUN:-true}" in
  true|1|yes)
    printf '%s\n' 'DRY_RUN=true: VERSION, Git refs, image, Release, and workflow state are unchanged.'
    exit 0
    ;;
  false|0|no) ;;
  *) printf '%s\n' 'DRY_RUN must be true or false' >&2; exit 1 ;;
esac

remote="$(git -C "$ONE_NODE_DIR" config --get remote.origin.url)"
case "$remote" in
  "https://github.com/$ONE_NODE_REPOSITORY"|"https://github.com/$ONE_NODE_REPOSITORY.git"|\
  "git@github.com:$ONE_NODE_REPOSITORY"|"git@github.com:$ONE_NODE_REPOSITORY.git") ;;
  *) printf 'One Node origin must be %s, got %s\n' "$ONE_NODE_REPOSITORY" "$remote" >&2; exit 1 ;;
esac

remote_tag="$(git -C "$ONE_NODE_DIR" ls-remote --tags origin "refs/tags/$source_tag")"
if [[ -n "$remote_tag" ]]; then
  git -C "$ONE_NODE_DIR" fetch --quiet --no-tags origin "refs/tags/$source_tag"
  [[ "$(git -C "$ONE_NODE_DIR" show FETCH_HEAD:VERSION 2>/dev/null || true)" == "$VERSION" ]] || {
    printf 'Remote Node tag %s does not contain matching VERSION metadata.\n' "$source_tag" >&2
    exit 1
  }
  node_ref=$source_tag
else
  [[ -z "$(git -C "$ONE_NODE_DIR" status --porcelain --untracked-files=all)" ]] || {
    printf 'One Node worktree must be clean: %s\n' "$ONE_NODE_DIR" >&2
    exit 1
  }
  branch="$(git -C "$ONE_NODE_DIR" symbolic-ref --quiet --short HEAD)" || {
    printf '%s\n' 'One Node repository must be on a branch' >&2
    exit 1
  }
  git -C "$ONE_NODE_DIR" fetch --tags origin "refs/heads/$branch:refs/remotes/origin/$branch"
  [[ "$(git -C "$ONE_NODE_DIR" rev-parse HEAD)" == "$(git -C "$ONE_NODE_DIR" rev-parse "origin/$branch")" ]] || {
    printf 'One Node branch must exactly match origin/%s before release.\n' "$branch" >&2
    exit 1
  }
  make --no-print-directory -C "$ONE_NODE_DIR" test
  version_tmp="$(mktemp "$ONE_NODE_DIR/VERSION.tmp.XXXXXX")"
  trap 'rm -f "$version_tmp"' EXIT
  printf '%s\n' "$VERSION" >"$version_tmp"
  mv -f -- "$version_tmp" "$ONE_NODE_DIR/VERSION"
  trap - EXIT
  git -C "$ONE_NODE_DIR" add -- VERSION
  if ! git -C "$ONE_NODE_DIR" diff --cached --quiet -- VERSION; then
    git -C "$ONE_NODE_DIR" commit -m "chore: release $source_tag" -- VERSION
  fi
  if git -C "$ONE_NODE_DIR" show-ref --verify --quiet "refs/tags/$source_tag"; then
    [[ "$(git -C "$ONE_NODE_DIR" rev-list -n 1 "$source_tag")" == \
      "$(git -C "$ONE_NODE_DIR" rev-parse HEAD)" ]] \
      && [[ "$(git -C "$ONE_NODE_DIR" show "$source_tag:VERSION")" == "$VERSION" ]] || {
      printf 'Local Node tag %s does not match HEAD and VERSION.\n' "$source_tag" >&2
      exit 1
    }
  else
    git -C "$ONE_NODE_DIR" tag -a "$source_tag" -m "one-node $source_tag"
  fi
  git -C "$ONE_NODE_DIR" push --atomic origin \
    "HEAD:refs/heads/$branch" "refs/tags/$source_tag:refs/tags/$source_tag"
  node_ref=$source_tag
fi

action_sha="$(GH_TOKEN="${GH_TOKEN:-}" bash "$PROJECT_ROOT/scripts/github/resolve-ref.sh" \
  voiceofhu/one-action "${ACTION_REF:-main}")"
CONFIRM_DISPATCH="dispatch:node.yml:$action_sha" \
CONFIRM_MUTATION="mutate:node.yml:$action_sha" \
DRY_RUN=false \
  exec bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" node.yml \
    node_repository="$ONE_NODE_REPOSITORY" node_ref="$node_ref" \
    version="$VERSION" publish=true deploy=false
