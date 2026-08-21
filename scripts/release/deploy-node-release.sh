#!/usr/bin/env bash
set -Eeuo pipefail
unset GH_TOKEN GITHUB_TOKEN CONFIRM_DISPATCH CONFIRM_MUTATION

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
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

source_tag="v$VERSION"
printf '%s\n' \
  'One Node release plan:' \
  "  version:    $VERSION" \
  "  source:     $ONE_NODE_REPOSITORY" \
  "  source tag: $source_tag" \
  "  release:    $ONE_NODE_REPOSITORY@$source_tag" \
  "  trigger:    $ACTION_REPOSITORY/.github/workflows/node.yml (workflow_dispatch)" \
  '  image:      ghcr.io/voiceofhu/one-node:<version>'

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

action_head="$(validate_action_repository)"
git -C "$PROJECT_ROOT" fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
[[ "$action_head" == "$(git -C "$PROJECT_ROOT" rev-parse refs/remotes/origin/main)" ]] || {
  printf '%s\n' 'Action HEAD must exactly match published origin/main before release.' >&2
  exit 1
}
make --no-print-directory -C "$PROJECT_ROOT" validate
[[ "$(validate_action_repository)" == "$action_head" ]] || {
  printf '%s\n' 'Action source changed during local validation.' >&2
  exit 1
}

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
  node_ref="$(git -C "$ONE_NODE_DIR" rev-parse 'FETCH_HEAD^{commit}')"
  [[ -z "$(git -C "$ONE_NODE_DIR" status --porcelain --untracked-files=all)" \
    && "$(git -C "$ONE_NODE_DIR" rev-parse HEAD)" == "$node_ref" ]] || {
    printf 'Local One Node checkout must exactly match existing remote tag %s before verification.\n' \
      "$source_tag" >&2
    exit 1
  }
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
  node_ref="$(git -C "$ONE_NODE_DIR" rev-parse HEAD)"
fi

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

if [[ -z "$remote_tag" ]]; then
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
  node_ref="$(git -C "$ONE_NODE_DIR" rev-parse HEAD)"
fi

[[ "$node_ref" =~ ^[0-9a-f]{40}$ ]] || {
  printf '%s\n' 'Resolved Node release source is not an exact commit SHA.' >&2
  exit 1
}

command -v gh >/dev/null 2>&1 || {
  printf '%s\n' 'gh is required to dispatch the One Node workflow' >&2
  exit 1
}
if ! gh workflow run node.yml \
  --repo "$ACTION_REPOSITORY" \
  --ref main \
  --field "version=$VERSION" \
  --field "expected_action_sha=$action_head"; then
  printf '%s\n' \
    "Node source tag $source_tag was published, but workflow dispatch failed." \
    "Retry with: gh workflow run node.yml --repo $ACTION_REPOSITORY --ref main --field version=$VERSION --field expected_action_sha=$action_head" >&2
  exit 1
fi
printf 'Triggered One Node image and Node-repository Release upload: %s@%s -> %s@%s\n' \
  "$ACTION_REPOSITORY" "$action_head" "$ONE_NODE_REPOSITORY" "$source_tag"
