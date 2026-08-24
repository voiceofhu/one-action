#!/usr/bin/env bash
set -Eeuo pipefail
github_token=${GH_TOKEN:-}
unset GH_TOKEN GITHUB_TOKEN CONFIRM_DISPATCH CONFIRM_MUTATION

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION_REPOSITORY='voiceofhu/one-action'

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

validate_action_repository() {
  local remote branch status

  [[ -d "$PROJECT_ROOT/.git" ]] || {
    printf 'Action repository is missing: %s\n' "$PROJECT_ROOT" >&2
    exit 1
  }
  remote="$(git -C "$PROJECT_ROOT" config --get remote.origin.url)"
  case "$remote" in
    "https://github.com/$ACTION_REPOSITORY"|"https://github.com/$ACTION_REPOSITORY.git"|\
    "git@github.com:$ACTION_REPOSITORY"|"git@github.com:$ACTION_REPOSITORY.git") ;;
    *)
      printf 'Action origin must be the fixed repository %s, got %s\n' \
        "$ACTION_REPOSITORY" "$remote" >&2
      exit 1
      ;;
  esac
  branch="$(git -C "$PROJECT_ROOT" symbolic-ref --quiet --short HEAD)" || {
    printf '%s\n' 'Action repository must be on the main branch' >&2
    exit 1
  }
  [[ "$branch" == main ]] || {
    printf 'Action repository must be on the main branch, got %s\n' "$branch" >&2
    exit 1
  }
  status="$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)"
  [[ -z "$status" ]] || {
    printf 'Action repository must be clean:\n%s\n' "$status" >&2
    exit 1
  }
  git -C "$PROJECT_ROOT" rev-parse --verify HEAD
}

backend_state="$(validate_source_repository \
  Backend "$ONE_USER_BACKEND_DIR" "$ONE_USER_BACKEND_REPOSITORY" Cargo.toml)"
web_state="$(validate_source_repository \
  Web "$ONE_USER_WEB_DIR" "$ONE_USER_WEB_REPOSITORY" package.json)"
backend_branch=${backend_state%%|*}
backend_head=${backend_state#*|}
web_branch=${web_state%%|*}
web_head=${web_state#*|}
action_head="$(git -C "$PROJECT_ROOT" rev-parse --verify HEAD)"

printf '%s\n' \
  'One User release plan:' \
  "  version:          $VERSION" \
  "  backend:          $ONE_USER_BACKEND_REPOSITORY@$backend_head" \
  "  web:              $ONE_USER_WEB_REPOSITORY@$web_head" \
  "  backend branch:   $backend_branch" \
  "  web branch:       $web_branch" \
  "  action:           $ACTION_REPOSITORY@$action_head" \
  '  trigger:          workflow_dispatch'

if [[ "$dry_run" == true ]]; then
	printf '%s\n' \
		  'DRY_RUN=true: checks, source versions, commits, pushes, dispatch, uploads, and deployment are not changed.' \
		  'The real run checks both sources, publishes version commits, then dispatches image publication and deployment.'
  exit 0
fi

validated_action_head="$(validate_action_repository)"
[[ "$action_head" == "$validated_action_head" ]] || {
  printf '%s\n' 'Action HEAD changed while preparing the release; no source repositories were changed.' >&2
  exit 1
}

if ! git -C "$PROJECT_ROOT" fetch --no-tags origin \
  '+refs/heads/main:refs/remotes/origin/main'; then
  printf '%s\n' \
    'Could not refresh Action origin/main; no source repositories were changed.' >&2
  exit 1
fi
action_remote_head="$(git -C "$PROJECT_ROOT" rev-parse --verify refs/remotes/origin/main)"
[[ "$action_head" == "$action_remote_head" ]] || {
  printf '%s\n' \
    "Action HEAD must exactly match published origin/main before release." \
    "  local:  $action_head" \
    "  remote: $action_remote_head" \
    'Push or synchronize the Action main branch, then retry; no source repositories were changed.' >&2
  exit 1
}
make --no-print-directory -C "$PROJECT_ROOT" validate-user
[[ "$(validate_action_repository)" == "$action_head" ]] || {
  printf '%s\n' 'Action source changed during local validation.' >&2
  exit 1
}

preflight_release_repository() {
  local label=$1
  local directory=$2
  local branch=$3

  git -C "$directory" fetch --no-tags origin \
    "refs/heads/$branch:refs/remotes/origin/$branch"
  git -C "$directory" show-ref --verify --quiet "refs/remotes/origin/$branch" || {
    printf '%s remote branch origin/%s was not found\n' "$label" "$branch" >&2
    exit 1
  }
  git -C "$directory" merge-base --is-ancestor "origin/$branch" HEAD || {
    printf '%s branch is behind or diverged from origin/%s\n' "$label" "$branch" >&2
    exit 1
  }
}

preflight_release_repository Backend "$ONE_USER_BACKEND_DIR" "$backend_branch"
preflight_release_repository Web "$ONE_USER_WEB_DIR" "$web_branch"

(
  cd "$ONE_USER_BACKEND_DIR"
  cargo fmt --all -- --check
)
make --no-print-directory -C "$ONE_USER_BACKEND_DIR" test
pnpm --dir "$ONE_USER_WEB_DIR" install --frozen-lockfile
pnpm --dir "$ONE_USER_WEB_DIR" format:check
pnpm --dir "$ONE_USER_WEB_DIR" lint
pnpm --dir "$ONE_USER_WEB_DIR" test
pnpm --dir "$ONE_USER_WEB_DIR" build

[[ "$(git -C "$ONE_USER_BACKEND_DIR" rev-parse HEAD)" == "$backend_head" \
  && -z "$(git -C "$ONE_USER_BACKEND_DIR" status --porcelain --untracked-files=all)" ]] || {
  printf '%s\n' 'Backend source changed during local validation.' >&2
  exit 1
}
[[ "$(git -C "$ONE_USER_WEB_DIR" rev-parse HEAD)" == "$web_head" \
  && -z "$(git -C "$ONE_USER_WEB_DIR" status --porcelain --untracked-files=all)" ]] || {
  printf '%s\n' 'Web source changed during local validation.' >&2
  exit 1
}

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
if ! git -C "$ONE_USER_BACKEND_DIR" diff --cached --quiet; then
  git -C "$ONE_USER_BACKEND_DIR" commit -m \
    "chore: bump one-user-backend version to $VERSION"
fi

git -C "$ONE_USER_WEB_DIR" add -- package.json
if ! git -C "$ONE_USER_WEB_DIR" diff --cached --quiet; then
  git -C "$ONE_USER_WEB_DIR" commit -m \
    "chore: bump one-user-web version to $VERSION"
fi

if ! git -C "$ONE_USER_BACKEND_DIR" push origin \
  "HEAD:refs/heads/$backend_branch"; then
  printf '%s\n' 'Backend version commit push failed; dispatch was not attempted.' >&2
  exit 1
fi
if ! git -C "$ONE_USER_WEB_DIR" push origin \
  "HEAD:refs/heads/$web_branch"; then
  printf '%s\n' \
    'Web version commit push failed; dispatch was not attempted.' \
    'Backend version commit may already be published.' >&2
  exit 1
fi

backend_release_sha="$(git -C "$ONE_USER_BACKEND_DIR" rev-parse HEAD)"
web_release_sha="$(git -C "$ONE_USER_WEB_DIR" rev-parse HEAD)"
printf '%s\n' \
  "Published Backend source: $ONE_USER_BACKEND_REPOSITORY@$backend_release_sha" \
  "Published Web source: $ONE_USER_WEB_REPOSITORY@$web_release_sha"

CONFIRM_DISPATCH="dispatch:user.yml:$action_head" \
CONFIRM_MUTATION="mutate:user.yml:$action_head" \
DRY_RUN=false \
ACTION_REPOSITORY="$ACTION_REPOSITORY" \
ACTION_REF=main \
GH_TOKEN="$github_token" \
bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" user.yml \
  "backend_repository=$ONE_USER_BACKEND_REPOSITORY" \
  "backend_ref=$backend_release_sha" \
  "web_repository=$ONE_USER_WEB_REPOSITORY" \
  "web_ref=$web_release_sha" \
  "version=$VERSION" \
  'publish=true'
printf 'Dispatched One User image publication and server deployment at Action %s.\n' \
  "$action_head"
