#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCHER="$PROJECT_ROOT/scripts/github/dispatch-workflow.sh"
RESOLVER="$PROJECT_ROOT/scripts/github/resolve-ref.sh"

: "${VERSION:?VERSION is required}"
: "${ONE_USER_BACKEND_DIR:?ONE_USER_BACKEND_DIR is required}"
: "${ONE_USER_WEB_DIR:?ONE_USER_WEB_DIR is required}"
: "${ONE_USER_BACKEND_REPOSITORY:?ONE_USER_BACKEND_REPOSITORY is required}"
: "${ONE_USER_WEB_REPOSITORY:?ONE_USER_WEB_REPOSITORY is required}"

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
  local label=$1
  local directory=$2
  local expected_repository=$3
  local expected_manifest=$4
  local remote branch status

  [[ -d "$directory/.git" ]] || {
    printf '%s source repository is missing: %s\n' "$label" "$directory" >&2
    exit 1
  }
  [[ -f "$directory/$expected_manifest" ]] || {
    printf '%s version manifest is missing: %s\n' "$label" "$expected_manifest" >&2
    exit 1
  }
  remote="$(git -C "$directory" config --get remote.origin.url)"
  case "$remote" in
    "https://github.com/$expected_repository"|"https://github.com/$expected_repository.git"|\
    "git@github.com:$expected_repository"|"git@github.com:$expected_repository.git") ;;
    *)
      printf '%s origin must be the fixed repository %s, got %s\n' \
        "$label" "$expected_repository" "$remote" >&2
      exit 1
      ;;
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

backend_state="$(validate_source_repository \
  Backend "$ONE_USER_BACKEND_DIR" "$ONE_USER_BACKEND_REPOSITORY" Cargo.toml)"
web_state="$(validate_source_repository \
  Web "$ONE_USER_WEB_DIR" "$ONE_USER_WEB_REPOSITORY" package.json)"
backend_branch=${backend_state%%|*}
backend_head=${backend_state#*|}
web_branch=${web_state%%|*}
web_head=${web_state#*|}
release_tag="v$VERSION"

printf '%s\n' \
  'One User release plan:' \
  "  version:          $VERSION" \
  "  tag:              $release_tag" \
  "  backend:          $ONE_USER_BACKEND_REPOSITORY@$backend_head" \
  "  web:              $ONE_USER_WEB_REPOSITORY@$web_head" \
  "  backend branch:   $backend_branch" \
  "  web branch:       $web_branch"

dispatch() {
  local action_ref=$1
  local backend_ref=$2
  local web_ref=$3
  local dispatch_dry_run=$4
  ACTION_REF="$action_ref" DRY_RUN="$dispatch_dry_run" \
    bash "$DISPATCHER" user.yml \
      backend_repository="$ONE_USER_BACKEND_REPOSITORY" \
      backend_ref="$backend_ref" \
      web_repository="$ONE_USER_WEB_REPOSITORY" \
      web_ref="$web_ref" \
      version="$VERSION" environment=prod publish=true deploy=true
}

if [[ "$dry_run" == true ]]; then
  printf '%s\n' \
    'DRY_RUN=true: source versions, commits, tags, pushes, dispatch, and deployment are not changed.' \
    'The real run will update both source versions before dispatching their new exact commits.'
  exit 0
fi

: "${GH_TOKEN:?GH_TOKEN is required}"
action_sha="$(GH_TOKEN="$GH_TOKEN" bash "$RESOLVER" \
  "${ACTION_REPOSITORY:-voiceofhu/one-action}" "${ACTION_REF:-main}")"
expected_dispatch="dispatch:user.yml:$action_sha"
expected_mutation="mutate:user.yml:$action_sha"
[[ "${CONFIRM_DISPATCH:-}" == "$expected_dispatch" ]] || {
  printf 'Real release requires CONFIRM_DISPATCH=%s\n' "$expected_dispatch" >&2
  exit 1
}
[[ "${CONFIRM_MUTATION:-}" == "$expected_mutation" ]] || {
  printf 'Real release requires CONFIRM_MUTATION=%s\n' "$expected_mutation" >&2
  exit 1
}

preflight_release_repository() {
  local label=$1
  local directory=$2
  local branch=$3

  git -C "$directory" fetch --tags origin \
    "refs/heads/$branch:refs/remotes/origin/$branch"
  git -C "$directory" show-ref --verify --quiet "refs/remotes/origin/$branch" || {
    printf '%s remote branch origin/%s was not found\n' "$label" "$branch" >&2
    exit 1
  }
  git -C "$directory" merge-base --is-ancestor "origin/$branch" HEAD || {
    printf '%s branch is behind or diverged from origin/%s\n' "$label" "$branch" >&2
    exit 1
  }
  ! git -C "$directory" rev-parse -q --verify "refs/tags/$release_tag" >/dev/null || {
    printf '%s tag already exists: %s\n' "$label" "$release_tag" >&2
    exit 1
  }
}

preflight_release_repository Backend "$ONE_USER_BACKEND_DIR" "$backend_branch"
preflight_release_repository Web "$ONE_USER_WEB_DIR" "$web_branch"

update_backend_version() {
  local manifest="$ONE_USER_BACKEND_DIR/Cargo.toml"
  local lockfile="$ONE_USER_BACKEND_DIR/Cargo.lock"
  local temp

  temp="$(mktemp "$manifest.tmp.XXXXXX")"
  awk -v version="$VERSION" '
    BEGIN { in_package=0; changed=0 }
    /^\[package\][[:space:]]*$/ { in_package=1; print; next }
    /^\[/ { in_package=0 }
    in_package && /^[[:space:]]*version[[:space:]]*=/ {
      if (changed != 0) exit 42
      print "version = \"" version "\""
      changed=1
      next
    }
    { print }
    END { if (changed != 1) exit 42 }
  ' "$manifest" >"$temp" || {
    rm -f -- "$temp"
    printf '%s\n' 'Could not update the unique backend package version' >&2
    exit 1
  }
  mv -f -- "$temp" "$manifest"

  temp="$(mktemp "$lockfile.tmp.XXXXXX")"
  awk -v version="$VERSION" '
    BEGIN { in_package=0; is_target=0; changed=0 }
    /^\[\[package\]\][[:space:]]*$/ { in_package=1; is_target=0; print; next }
    in_package && /^name = "one-user-backend"[[:space:]]*$/ { is_target=1; print; next }
    in_package && is_target && /^version = / {
      if (changed != 0) exit 42
      print "version = \"" version "\""
      changed=1
      next
    }
    { print }
    END { if (changed != 1) exit 42 }
  ' "$lockfile" >"$temp" || {
    rm -f -- "$temp"
    printf '%s\n' 'Could not update the unique backend lockfile version' >&2
    exit 1
  }
  mv -f -- "$temp" "$lockfile"
}

update_web_version() {
  VERSION="$VERSION" node - <<'NODE' "$ONE_USER_WEB_DIR/package.json"
const fs = require('node:fs');
const file = process.argv[2];
const document = JSON.parse(fs.readFileSync(file, 'utf8'));
if (document.name !== 'one-user-web' || typeof document.version !== 'string') {
  throw new Error('package.json does not describe one-user-web');
}
document.version = process.env.VERSION;
fs.writeFileSync(file, `${JSON.stringify(document, null, 2)}\n`);
NODE
}

verify_changed_paths() {
  local label=$1
  local directory=$2
  local expected=$3
  local actual
  actual="$(git -C "$directory" diff --name-only | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
  [[ "$actual" == "$expected" ]] || {
    printf '%s version update changed unexpected paths: %s\n' "$label" "${actual:-none}" >&2
    exit 1
  }
}

update_backend_version
update_web_version
verify_changed_paths Backend "$ONE_USER_BACKEND_DIR" 'Cargo.lock Cargo.toml'
verify_changed_paths Web "$ONE_USER_WEB_DIR" 'package.json'

git -C "$ONE_USER_BACKEND_DIR" add -- Cargo.toml Cargo.lock
git -C "$ONE_USER_BACKEND_DIR" commit -m \
  "chore: bump one-user-backend version to $release_tag"
git -C "$ONE_USER_BACKEND_DIR" tag "$release_tag"

git -C "$ONE_USER_WEB_DIR" add -- package.json
git -C "$ONE_USER_WEB_DIR" commit -m \
  "chore: bump one-user-web version to $release_tag"
git -C "$ONE_USER_WEB_DIR" tag "$release_tag"

git -C "$ONE_USER_BACKEND_DIR" push --atomic origin \
  "HEAD:refs/heads/$backend_branch" "refs/tags/$release_tag:refs/tags/$release_tag"
git -C "$ONE_USER_WEB_DIR" push --atomic origin \
  "HEAD:refs/heads/$web_branch" "refs/tags/$release_tag:refs/tags/$release_tag"

backend_release_sha="$(git -C "$ONE_USER_BACKEND_DIR" rev-parse "$release_tag^{commit}")"
web_release_sha="$(git -C "$ONE_USER_WEB_DIR" rev-parse "$release_tag^{commit}")"
printf '%s\n' \
  "Published Backend source: $ONE_USER_BACKEND_REPOSITORY@$backend_release_sha" \
  "Published Web source: $ONE_USER_WEB_REPOSITORY@$web_release_sha"

dispatch "$action_sha" "$backend_release_sha" "$web_release_sha" false
