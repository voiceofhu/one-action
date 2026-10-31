#!/usr/bin/env bash
set -Eeuo pipefail

# Runs the shared Server release entry against throwaway Git remotes for one
# products.json product (default: every product).
# macOS /bin/bash 3.2 ignores a failed [[ ]] or ! under set -e, so checks say `|| fail`.
fail() {
  printf '%s: check failed at line %s\n' "${BASH_SOURCE[0]##*/}" "${BASH_LINENO[0]}" >&2
  exit 1
}
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -eq 0 ]]; then
  for product in $(jq -r 'keys[]' "$PROJECT_ROOT/products.json"); do
    bash "${BASH_SOURCE[0]}" "$product"
  done
  exit 0
fi
# shellcheck source=scripts/lib/product.sh
source "$PROJECT_ROOT/scripts/lib/product.sh"
load_product "$1"
product_env_prefix="ONE_$(printf '%s' "$PRODUCT_KEY" | tr '[:lower:]' '[:upper:]')"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fake_bin="$test_dir/bin"
mkdir -p "$fake_bin"
export LOCAL_GATE_LOG="$test_dir/local-gates.log"
cat >"$fake_bin/make" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'make' >>"$LOCAL_GATE_LOG"
printf ' %s' "$@" >>"$LOCAL_GATE_LOG"
printf '\n' >>"$LOCAL_GATE_LOG"
EOF
cat >"$fake_bin/cargo" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'cargo' >>"$LOCAL_GATE_LOG"
printf ' %s' "$@" >>"$LOCAL_GATE_LOG"
printf '\n' >>"$LOCAL_GATE_LOG"
EOF
cat >"$fake_bin/go" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'go' >>"$LOCAL_GATE_LOG"
printf ' %s' "$@" >>"$LOCAL_GATE_LOG"
printf '\n' >>"$LOCAL_GATE_LOG"
EOF
cat >"$fake_bin/pnpm" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'pnpm' >>"$LOCAL_GATE_LOG"
printf ' %s' "$@" >>"$LOCAL_GATE_LOG"
printf '\n' >>"$LOCAL_GATE_LOG"
EOF
chmod 0755 "$fake_bin/make" "$fake_bin/cargo" "$fake_bin/go" "$fake_bin/pnpm"
export PATH="$fake_bin:$PATH"
export DRY_RUN=false
export VERSION=26.815.1234
backend_dir="$test_dir/backend"
web_dir="$test_dir/web"
export "${product_env_prefix}_BACKEND_DIR=$backend_dir"
export "${product_env_prefix}_WEB_DIR=$web_dir"
: >"$LOCAL_GATE_LOG"

backend_bare="$test_dir/backend-origin.git"
web_bare="$test_dir/web-origin.git"
action_bare="$test_dir/action-origin.git"
action_dir="$test_dir/action"
git init -q --bare "$backend_bare"
git init -q --bare "$web_bare"
git init -q --bare "$action_bare"
git init -q "$backend_dir"
git init -q "$web_dir"
git init -q "$action_dir"

for repository in "$backend_dir" "$web_dir" "$action_dir"; do
  git -C "$repository" config user.name test
  git -C "$repository" config user.email test@example.invalid
  git -C "$repository" checkout -qb main
done

if [[ "$PRODUCT_BACKEND_LANGUAGE" == go ]]; then
  printf '%s\n' "module example.invalid/$PRODUCT_BACKEND_PACKAGE" '' 'go 1.25' >"$backend_dir/go.mod"
  git -C "$backend_dir" add go.mod
else
  printf '%s\n' '[package]' "name = \"$PRODUCT_BACKEND_PACKAGE\"" 'version = "0.1.0"' \
    >"$backend_dir/Cargo.toml"
  printf '%s\n' 'version = 4' '' '[[package]]' "name = \"$PRODUCT_BACKEND_PACKAGE\"" 'version = "0.1.0"' \
    >"$backend_dir/Cargo.lock"
  git -C "$backend_dir" add Cargo.toml Cargo.lock
fi
git -C "$backend_dir" commit -qm initial
git -C "$backend_dir" remote add origin \
  "https://github.com/$PRODUCT_BACKEND_REPOSITORY.git"
git -C "$backend_dir" config \
  url."file://$backend_bare".insteadOf \
  "https://github.com/$PRODUCT_BACKEND_REPOSITORY.git"
git -C "$backend_dir" push -q -u origin main

printf '%s\n' '{' "  \"name\": \"$PRODUCT_WEB_PACKAGE\"," '  "private": true,' '  "version": "0.1.0"' '}' \
  >"$web_dir/package.json"
git -C "$web_dir" add package.json
git -C "$web_dir" commit -qm initial
git -C "$web_dir" remote add origin \
  "https://github.com/$PRODUCT_WEB_REPOSITORY.git"
git -C "$web_dir" config \
  url."file://$web_bare".insteadOf \
  "https://github.com/$PRODUCT_WEB_REPOSITORY.git"
git -C "$web_dir" push -q -u origin main

# Run from a temporary canonical One Action repository so the deploy tag
# cannot touch the developer's real checkout.
mkdir -p "$action_dir/scripts/release" "$action_dir/scripts/github" "$action_dir/scripts/lib" \
  "$action_dir/.github/workflows"
cp "$PROJECT_ROOT/products.json" "$action_dir/products.json"
cp "$PROJECT_ROOT/scripts/lib/product.sh" "$action_dir/scripts/lib/product.sh"
cp "$PROJECT_ROOT/scripts/lib/git-remote.sh" "$action_dir/scripts/lib/git-remote.sh"
cp "$PROJECT_ROOT/scripts/release/release-server.sh" "$PROJECT_ROOT/scripts/release/trigger.sh" \
  "$action_dir/scripts/release/"
cp "$PROJECT_ROOT/scripts/github/read-trigger.sh" "$action_dir/scripts/github/"
cp "$PROJECT_ROOT/.github/workflows/$PRODUCT_SERVER_WORKFLOW" "$action_dir/.github/workflows/"
git -C "$action_dir" add products.json scripts .github
git -C "$action_dir" commit -qm initial
git -C "$action_dir" remote add origin https://github.com/voiceofhu/one-action.git
git -C "$action_dir" config \
  url."file://$action_bare".insteadOf \
  https://github.com/voiceofhu/one-action.git
git -C "$action_dir" push -q -u origin main

env -u GH_TOKEN -u GITHUB_TOKEN \
  bash "$action_dir/scripts/release/release-server.sh" "$PRODUCT_KEY" >"$test_dir/output"

if [[ "$PRODUCT_BACKEND_LANGUAGE" == rust ]]; then
  grep -Fq 'version = "26.815.1234"' "$backend_dir/Cargo.toml"
  grep -Fq 'version = "26.815.1234"' "$backend_dir/Cargo.lock"
  git --git-dir="$backend_bare" show refs/heads/main:Cargo.toml |
    grep -Fq 'version = "26.815.1234"'
else
  # Go has no version file: the Backend must be released at its existing commit.
  [[ "$(git --git-dir="$backend_bare" rev-list --count refs/heads/main)" == 1 ]] || fail
fi
node -e '
  const p = require(process.argv[1]);
  if (p.version !== "26.815.1234") process.exit(1);
' "$web_dir/package.json"

if git --git-dir="$backend_bare" for-each-ref --format='%(refname)' refs/tags | grep -q . ||
  git --git-dir="$web_bare" for-each-ref --format='%(refname)' refs/tags | grep -q .; then
  printf '%s release tagged a private source repository.\n' "$PRODUCT_TITLE" >&2
  exit 1
fi
git --git-dir="$web_bare" show refs/heads/main:package.json |
  grep -Fq '"version": "26.815.1234"'

backend_sha="$(git --git-dir="$backend_bare" rev-parse refs/heads/main)"
web_sha="$(git --git-dir="$web_bare" rev-parse refs/heads/main)"
tag="deploy/$PRODUCT_KEY-server/26.815.1234"
[[ "$(git --git-dir="$action_bare" for-each-ref --format='%(refname)' refs/tags)" == "refs/tags/$tag" ]] || fail
action_sha="$(git --git-dir="$action_bare" rev-parse refs/heads/main)"

# The workflow side reads the pushed tag back exactly as Actions would.
runner_dir="$test_dir/runner"
git clone -q "$action_bare" "$runner_dir"
GITHUB_REPOSITORY=voiceofhu/one-action GITHUB_REF_TYPE=tag GITHUB_REF="refs/tags/$tag" \
  GITHUB_SHA="$action_sha" \
  bash -c 'cd "$1" && bash scripts/github/read-trigger.sh "$2-server" backend_ref web_ref' \
  _ "$runner_dir" "$PRODUCT_KEY" >"$test_dir/trigger"
printf '%s\n' version=26.815.1234 "backend_ref=$backend_sha" "web_ref=$web_sha" |
  cmp -s - "$test_dir/trigger" || {
  printf 'Deploy tag did not round-trip:\n' >&2
  cat "$test_dir/trigger" >&2
  exit 1
}

require_gate() {
  grep -Fxq "$1" "$LOCAL_GATE_LOG" || {
    printf 'Missing local release gate: %s\n' "$1" >&2
    exit 1
  }
}
require_gate "make --no-print-directory -C $action_dir validate-$PRODUCT_KEY"
if [[ "$PRODUCT_BACKEND_LANGUAGE" == go ]]; then
  require_gate 'go vet ./...'
else
  require_gate 'cargo fmt --all -- --check'
fi
require_gate "make --no-print-directory -C $backend_dir test"
require_gate "pnpm --dir $web_dir install --frozen-lockfile"
for gate in "${PRODUCT_WEB_GATES[@]}"; do
  require_gate "pnpm --dir $web_dir $gate"
done

printf '%s version commits triggered a deploy tag pinning exact SHAs.\n' "$PRODUCT_TITLE"
