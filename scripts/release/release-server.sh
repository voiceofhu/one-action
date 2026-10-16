#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/git-remote.sh
source "$PROJECT_ROOT/scripts/lib/git-remote.sh"
ACTION_REPOSITORY='voiceofhu/one-action'
# shellcheck source=scripts/lib/product.sh
source "$PROJECT_ROOT/scripts/lib/product.sh"

[[ "$#" -eq 1 ]] || product_die 'usage: release-server.sh PRODUCT'
load_product "$1"
: "${VERSION:?VERSION is required}"
SOURCE_ROOT=${SOURCE_ROOT:-$(cd -- "$PROJECT_ROOT/.." && pwd)}
product_env_prefix="ONE_$(printf '%s' "$PRODUCT_KEY" | tr '[:lower:]' '[:upper:]')"
backend_dir_variable="${product_env_prefix}_BACKEND_DIR"
web_dir_variable="${product_env_prefix}_WEB_DIR"
backend_dir=${!backend_dir_variable:-$SOURCE_ROOT/$PRODUCT_NAME/backend}
web_dir=${!web_dir_variable:-$SOURCE_ROOT/$PRODUCT_NAME/web}
backend_repository=$PRODUCT_BACKEND_REPOSITORY
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
  remote="$(origin_remote_url "$directory")"
  is_github_remote "$remote" "$expected_repository" || {
    printf '%s origin must be the fixed repository %s, got %s\n' \
      "$label" "$expected_repository" "$remote" >&2
    exit 1
  }
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
  remote="$(origin_remote_url "$PROJECT_ROOT")"
  is_github_remote "$remote" "$ACTION_REPOSITORY" || {
    printf 'Action origin must be the fixed repository %s, got %s\n' \
      "$ACTION_REPOSITORY" "$remote" >&2
    exit 1
  }
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

case "$PRODUCT_BACKEND_LANGUAGE" in
  rust) backend_manifest=Cargo.toml ;;
  go) backend_manifest=go.mod ;;
esac
backend_state="$(validate_source_repository \
  Backend "$backend_dir" "$backend_repository" "$backend_manifest")"
web_state="$(validate_source_repository \
  Web "$web_dir" "$web_repository" package.json)"
backend_branch=${backend_state%%|*}
backend_head=${backend_state#*|}
web_branch=${web_state%%|*}
web_head=${web_state#*|}
action_head="$(git -C "$PROJECT_ROOT" rev-parse --verify HEAD)"

printf '%s\n' \
  "$PRODUCT_TITLE release plan:" \
  "  version:          $VERSION" \
  "  backend:          $backend_repository@$backend_head" \
  "  web:              $web_repository@$web_head" \
  "  backend branch:   $backend_branch" \
  "  web branch:       $web_branch" \
  "  action:           $ACTION_REPOSITORY@$action_head" \
  "  trigger:          tag deploy/$PRODUCT_KEY-server/$VERSION"

if [[ "$dry_run" == true ]]; then
	printf '%s\n' \
		  'DRY_RUN=true: checks, source versions, commits, pushes, tags, uploads, and deployment are not changed.' \
		  'The real run checks both sources, publishes version commits, then pushes the deploy tag that starts image publication and deployment.'
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
make --no-print-directory -C "$PROJECT_ROOT" "validate-$PRODUCT_KEY"
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

preflight_release_repository Backend "$backend_dir" "$backend_branch"
preflight_release_repository Web "$web_dir" "$web_branch"

(
  cd "$backend_dir"
  case "$PRODUCT_BACKEND_LANGUAGE" in
    rust) cargo fmt --all -- --check ;;
    go) go vet ./... ;;
  esac
)
make --no-print-directory -C "$backend_dir" test
pnpm --dir "$web_dir" install --frozen-lockfile
for gate in "${PRODUCT_WEB_GATES[@]}"; do
  pnpm --dir "$web_dir" "$gate"
done

[[ "$(git -C "$backend_dir" rev-parse HEAD)" == "$backend_head" \
  && -z "$(git -C "$backend_dir" status --porcelain --untracked-files=all)" ]] || {
  printf '%s\n' 'Backend source changed during local validation.' >&2
  exit 1
}
[[ "$(git -C "$web_dir" rev-parse HEAD)" == "$web_head" \
  && -z "$(git -C "$web_dir" status --porcelain --untracked-files=all)" ]] || {
  printf '%s\n' 'Web source changed during local validation.' >&2
  exit 1
}

update_backend_version() {
  local manifest="$backend_dir/Cargo.toml"
  local lockfile="$backend_dir/Cargo.lock"
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
  awk -v version="$VERSION" -v package="$PRODUCT_BACKEND_PACKAGE" '
    BEGIN { in_package=0; is_target=0; changed=0 }
    /^\[\[package\]\][[:space:]]*$/ { in_package=1; is_target=0; print; next }
    in_package && $0 == "name = \"" package "\"" { is_target=1; print; next }
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
  VERSION="$VERSION" WEB_PACKAGE="$PRODUCT_WEB_PACKAGE" node - <<'NODE' "$web_dir/package.json"
const fs = require('node:fs');
const file = process.argv[2];
const document = JSON.parse(fs.readFileSync(file, 'utf8'));
if (document.name !== process.env.WEB_PACKAGE || typeof document.version !== 'string') {
  throw new Error(`package.json does not describe ${process.env.WEB_PACKAGE}`);
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

# Go backends have no version file; the image build stamps VERSION via ldflags.
if [[ "$PRODUCT_BACKEND_LANGUAGE" == rust ]]; then
  update_backend_version
  verify_changed_paths Backend "$backend_dir" 'Cargo.lock Cargo.toml'
  git -C "$backend_dir" add -- Cargo.toml Cargo.lock
  if ! git -C "$backend_dir" diff --cached --quiet; then
    git -C "$backend_dir" commit -m \
      "chore: bump $PRODUCT_BACKEND_PACKAGE version to $VERSION"
  fi
fi
update_web_version
verify_changed_paths Web "$web_dir" 'package.json'

git -C "$web_dir" add -- package.json
if ! git -C "$web_dir" diff --cached --quiet; then
  git -C "$web_dir" commit -m \
    "chore: bump $PRODUCT_WEB_PACKAGE version to $VERSION"
fi

if ! git -C "$backend_dir" push origin \
  "HEAD:refs/heads/$backend_branch"; then
  printf '%s\n' 'Backend version commit push failed; the deploy tag was not pushed.' >&2
  exit 1
fi
if ! git -C "$web_dir" push origin \
  "HEAD:refs/heads/$web_branch"; then
  printf '%s\n' \
    'Web version commit push failed; the deploy tag was not pushed.' \
    'Backend version commit may already be published.' >&2
  exit 1
fi

backend_release_sha="$(git -C "$backend_dir" rev-parse HEAD)"
web_release_sha="$(git -C "$web_dir" rev-parse HEAD)"
printf '%s\n' \
  "Published Backend source: $backend_repository@$backend_release_sha" \
  "Published Web source: $web_repository@$web_release_sha"

DRY_RUN=false bash "$PROJECT_ROOT/scripts/release/trigger.sh" \
  "$PRODUCT_SERVER_WORKFLOW" "$action_head" "$VERSION" \
  "backend_ref=$backend_release_sha" \
  "web_ref=$web_release_sha"
