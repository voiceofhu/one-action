#!/usr/bin/env bash
set -Eeuo pipefail

# Runs the shared Web-only release entry against throwaway Git remotes for one
# products.json product (default: every product).
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
for command in make cargo pnpm; do
  printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' \
    '[[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]]' \
    "printf '$command' >>\"\$LOCAL_GATE_LOG\"" \
    'printf " %s" "$@" >>"$LOCAL_GATE_LOG"' \
    'printf "\n" >>"$LOCAL_GATE_LOG"' >"$fake_bin/$command"
  chmod 0755 "$fake_bin/$command"
done
export PATH="$fake_bin:$PATH"
export DRY_RUN=false
export VERSION=26.815.1234
backend_dir="$test_dir/backend"
web_dir="$test_dir/web"
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

printf '%s\n' '[package]' "name = \"$PRODUCT_BACKEND_PACKAGE\"" 'version = "0.1.0"' >"$backend_dir/Cargo.toml"
git -C "$backend_dir" add Cargo.toml
git -C "$backend_dir" commit -qm initial
git -C "$backend_dir" remote add origin "https://github.com/$PRODUCT_BACKEND_REPOSITORY.git"
git -C "$backend_dir" config url."file://$backend_bare".insteadOf \
  "https://github.com/$PRODUCT_BACKEND_REPOSITORY.git"
git -C "$backend_dir" push -q -u origin main

printf '%s\n' '{' "  \"name\": \"$PRODUCT_WEB_PACKAGE\"," '  "version": "0.1.0"' '}' \
  >"$web_dir/package.json"
git -C "$web_dir" add package.json
git -C "$web_dir" commit -qm initial
web_sha="$(git -C "$web_dir" rev-parse HEAD)"
git -C "$web_dir" remote add origin "https://github.com/$PRODUCT_WEB_REPOSITORY.git"
git -C "$web_dir" config url."file://$web_bare".insteadOf \
  "https://github.com/$PRODUCT_WEB_REPOSITORY.git"
git -C "$web_dir" push -q -u origin main

mkdir -p "$action_dir/scripts/release" "$action_dir/scripts/github" "$action_dir/scripts/lib" \
  "$action_dir/.github/workflows"
cp "$PROJECT_ROOT/products.json" "$action_dir/products.json"
cp "$PROJECT_ROOT/scripts/lib/product.sh" "$action_dir/scripts/lib/product.sh"
cp "$PROJECT_ROOT/scripts/lib/git-remote.sh" "$action_dir/scripts/lib/git-remote.sh"
cp "$PROJECT_ROOT/scripts/release/release-web.sh" "$PROJECT_ROOT/scripts/release/trigger.sh" \
  "$action_dir/scripts/release/"
cp "$PROJECT_ROOT/scripts/github/read-trigger.sh" "$action_dir/scripts/github/"
cp "$PROJECT_ROOT/.github/workflows/$PRODUCT_WEB_WORKFLOW" "$action_dir/.github/workflows/"
git -C "$action_dir" add products.json scripts .github
git -C "$action_dir" commit -qm initial
git -C "$action_dir" remote add origin https://github.com/voiceofhu/one-action.git
git -C "$action_dir" config url."file://$action_bare".insteadOf \
  https://github.com/voiceofhu/one-action.git
git -C "$action_dir" push -q -u origin main

env -u GH_TOKEN -u GITHUB_TOKEN \
  "${product_env_prefix}_BACKEND_DIR=$test_dir/no-server-checkout" \
  bash "$action_dir/scripts/release/release-web.sh" "$PRODUCT_KEY" >"$test_dir/output"

if git --git-dir="$backend_bare" show-ref --verify --quiet refs/tags/v26.815.1234 ||
  git --git-dir="$web_bare" show-ref --verify --quiet refs/tags/v26.815.1234; then
  printf '%s\n' 'Web trigger created a forbidden source tag.' >&2
  exit 1
fi
node -e '
  const p = require(process.argv[1]);
  if (p.version !== "0.1.0") process.exit(1);
' "$web_dir/package.json"

tag="deploy/$PRODUCT_KEY-web/26.815.1234"
[[ "$(git --git-dir="$action_bare" for-each-ref --format='%(refname)' refs/tags)" == "refs/tags/$tag" ]]
action_sha="$(git --git-dir="$action_bare" rev-parse refs/heads/main)"

# Read the pushed tag back through the same entry used by the Web workflow.
runner_dir="$test_dir/runner"
git clone -q "$action_bare" "$runner_dir"
GITHUB_REPOSITORY=voiceofhu/one-action GITHUB_REF_TYPE=tag GITHUB_REF="refs/tags/$tag" \
  GITHUB_SHA="$action_sha" \
  bash -c 'cd "$1" && bash scripts/github/read-trigger.sh "$2-web" web_ref' \
  _ "$runner_dir" "$PRODUCT_KEY" >"$test_dir/trigger"
printf '%s\n' version=26.815.1234 "web_ref=$web_sha" |
  cmp -s - "$test_dir/trigger" || {
  printf 'Web deploy tag did not round-trip:\n' >&2
  cat "$test_dir/trigger" >&2
  exit 1
}

require_gate() {
  grep -Fxq "$1" "$LOCAL_GATE_LOG" || {
    printf 'Missing local Web gate: %s\n' "$1" >&2
    exit 1
  }
}
require_gate "make --no-print-directory -C $action_dir validate-$PRODUCT_KEY-web"
require_gate "pnpm --dir $web_dir install --frozen-lockfile"
for gate in "${PRODUCT_WEB_GATES[@]}"; do
  require_gate "pnpm --dir $web_dir $gate"
done

printf '%s Web deploy tag pins its exact SHA without a Server checkout or Server build.\n' "$PRODUCT_TITLE"
