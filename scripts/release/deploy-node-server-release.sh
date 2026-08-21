#!/usr/bin/env bash
set -Eeuo pipefail
unset GH_TOKEN GITHUB_TOKEN CONFIRM_DISPATCH CONFIRM_MUTATION

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION_REPOSITORY=voiceofhu/one-action

: "${VERSION:?VERSION is required}"
: "${ONE_NODE_SERVER_DIR:?ONE_NODE_SERVER_DIR is required}"
: "${ONE_NODE_SERVER_REPOSITORY:?ONE_NODE_SERVER_REPOSITORY is required}"
: "${ONE_NODE_WEB_DIR:?ONE_NODE_WEB_DIR is required}"
: "${ONE_NODE_WEB_REPOSITORY:?ONE_NODE_WEB_REPOSITORY is required}"

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

server_state="$(validate_source_repository Server "$ONE_NODE_SERVER_DIR" "$ONE_NODE_SERVER_REPOSITORY" go.mod)"
web_state="$(validate_source_repository Web "$ONE_NODE_WEB_DIR" "$ONE_NODE_WEB_REPOSITORY" package.json)"
server_branch=${server_state%%|*}
server_head=${server_state#*|}
web_branch=${web_state%%|*}
web_head=${web_state#*|}
release_tag="v$VERSION"
control_tag="node-server-v$VERSION"
action_head="$(git -C "$PROJECT_ROOT" rev-parse --verify HEAD)"

printf '%s\n' \
  'One Node Server release plan:' \
  "  version:       $VERSION" \
  "  source tag:    $release_tag" \
  "  server:        $ONE_NODE_SERVER_REPOSITORY@$server_head" \
  "  web:           $ONE_NODE_WEB_REPOSITORY@$web_head" \
  "  server branch: $server_branch" \
  "  web branch:    $web_branch" \
  "  action:        $ACTION_REPOSITORY@$action_head" \
  "  control tag:   $control_tag"

if [[ "$dry_run" == true ]]; then
  printf '%s\n' \
    'DRY_RUN=true: checks, source tags, pushes, image publication, and uploads are unchanged.' \
    'The real run checks both sources, pushes their tags, then pushes the Action control tag.'
  exit 0
fi

[[ "$(validate_action_repository)" == "$action_head" ]]
! git -C "$PROJECT_ROOT" rev-parse -q --verify "refs/tags/$control_tag" >/dev/null || {
  printf 'Action control tag already exists locally: %s\n' "$control_tag" >&2
  exit 1
}

remote_control_tag_status=0
git -C "$PROJECT_ROOT" ls-remote --exit-code --tags origin \
  "refs/tags/$control_tag" "refs/tags/$control_tag^{}" >/dev/null || remote_control_tag_status=$?
case "$remote_control_tag_status" in
  0) printf 'Action control tag already exists remotely: %s\n' "$control_tag" >&2; exit 1 ;;
  2) ;;
  *) printf 'Could not check remote Action control tag %s.\n' "$control_tag" >&2; exit 1 ;;
esac

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

preflight_source() {
  local label=$1 directory=$2 branch=$3
  git -C "$directory" fetch --tags origin "refs/heads/$branch:refs/remotes/origin/$branch"
  git -C "$directory" merge-base --is-ancestor "origin/$branch" HEAD || {
    printf '%s branch is behind or diverged from origin/%s\n' "$label" "$branch" >&2
    exit 1
  }
  ! git -C "$directory" rev-parse -q --verify "refs/tags/$release_tag" >/dev/null || {
    printf '%s tag already exists: %s\n' "$label" "$release_tag" >&2
    exit 1
  }
}

preflight_source Server "$ONE_NODE_SERVER_DIR" "$server_branch"
preflight_source Web "$ONE_NODE_WEB_DIR" "$web_branch"

make --no-print-directory -C "$ONE_NODE_WEB_DIR" install check build
make --no-print-directory -C "$ONE_NODE_SERVER_DIR" test
(
  cd "$ONE_NODE_SERVER_DIR"
  go vet ./...
)
make --no-print-directory -C "$ONE_NODE_SERVER_DIR" build \
  VERSION="$VERSION" COMMIT="$server_head"

[[ "$(git -C "$ONE_NODE_SERVER_DIR" rev-parse HEAD)" == "$server_head" \
  && -z "$(git -C "$ONE_NODE_SERVER_DIR" status --porcelain --untracked-files=all)" ]] || {
  printf '%s\n' 'Server source changed during local validation.' >&2
  exit 1
}
[[ "$(git -C "$ONE_NODE_WEB_DIR" rev-parse HEAD)" == "$web_head" \
  && -z "$(git -C "$ONE_NODE_WEB_DIR" status --porcelain --untracked-files=all)" ]] || {
  printf '%s\n' 'Web source changed during local validation.' >&2
  exit 1
}

VERSION="$VERSION" node - <<'NODE' "$ONE_NODE_WEB_DIR/package.json"
const fs = require('node:fs');
const file = process.argv[2];
const document = JSON.parse(fs.readFileSync(file, 'utf8'));
if (document.name !== 'one-node-web-vite' || typeof document.version !== 'string') {
  throw new Error('package.json does not describe one-node-web-vite');
}
document.version = process.env.VERSION;
fs.writeFileSync(file, `${JSON.stringify(document, null, 2)}\n`);
NODE
web_version_change="$(git -C "$ONE_NODE_WEB_DIR" diff --name-only)"
case "$web_version_change" in
  '') ;;
  package.json)
    git -C "$ONE_NODE_WEB_DIR" add -- package.json
    git -C "$ONE_NODE_WEB_DIR" commit -m "chore: bump one-node-web version to $release_tag"
    ;;
  *) printf 'Web version update changed unexpected paths: %s\n' "$web_version_change" >&2; exit 1 ;;
esac
web_head="$(git -C "$ONE_NODE_WEB_DIR" rev-parse HEAD)"

git -C "$ONE_NODE_SERVER_DIR" tag "$release_tag" "$server_head"
git -C "$ONE_NODE_WEB_DIR" tag "$release_tag" "$web_head"
git -C "$ONE_NODE_SERVER_DIR" push --atomic origin \
  "HEAD:refs/heads/$server_branch" "refs/tags/$release_tag:refs/tags/$release_tag"
if ! git -C "$ONE_NODE_WEB_DIR" push --atomic origin \
  "HEAD:refs/heads/$web_branch" "refs/tags/$release_tag:refs/tags/$release_tag"; then
  printf '%s\n' \
    "Web push failed; local tag $release_tag was kept." \
    'Server may already be published; the Action control tag was not created.' >&2
  exit 1
fi

git -C "$PROJECT_ROOT" tag "$control_tag" "$action_head"
if ! git -C "$PROJECT_ROOT" push origin "refs/tags/$control_tag:refs/tags/$control_tag"; then
  printf '%s\n' \
    "Source tags were published and local control tag $control_tag was kept." \
    "Recover with: git -C $PROJECT_ROOT push origin refs/tags/$control_tag:refs/tags/$control_tag" >&2
  exit 1
fi
printf 'Triggered One Node Server image compilation and upload with Action control tag: %s@%s\n' \
  "$control_tag" "$action_head"
