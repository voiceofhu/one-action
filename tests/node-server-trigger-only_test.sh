#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fake_bin="$test_dir/bin"
mkdir -p "$fake_bin"
export LOCAL_GATE_LOG="$test_dir/local-gates.log"
for command in make go; do
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
export ONE_NODE_SERVER_REPOSITORY=voiceofhu/one-node-server
export ONE_NODE_WEB_REPOSITORY=voiceofhu/one-node-web
export ONE_NODE_SERVER_DIR="$test_dir/backend"
export ONE_NODE_WEB_DIR="$test_dir/web"
export GH_TOKEN=abcdefghijklmnopqrstuvwxyz123456
unset GITHUB_TOKEN CONFIRM_DISPATCH CONFIRM_MUTATION
export DISPATCH_LOG="$test_dir/dispatch.log"
: >"$LOCAL_GATE_LOG"

backend_bare="$test_dir/backend-origin.git"
web_bare="$test_dir/web-origin.git"
action_bare="$test_dir/action-origin.git"
action_dir="$test_dir/action"
git init -q --bare "$backend_bare"
git init -q --bare "$web_bare"
git init -q --bare "$action_bare"
git init -q "$ONE_NODE_SERVER_DIR"
git init -q "$ONE_NODE_WEB_DIR"
git init -q "$action_dir"

for repository in "$ONE_NODE_SERVER_DIR" "$ONE_NODE_WEB_DIR" "$action_dir"; do
  git -C "$repository" config user.name test
  git -C "$repository" config user.email test@example.invalid
  git -C "$repository" checkout -qb main
done

printf '%s\n' 'module example.invalid/one-node-server' 'go 1.25' >"$ONE_NODE_SERVER_DIR/go.mod"
git -C "$ONE_NODE_SERVER_DIR" add go.mod
git -C "$ONE_NODE_SERVER_DIR" commit -qm initial
server_sha="$(git -C "$ONE_NODE_SERVER_DIR" rev-parse HEAD)"
git -C "$ONE_NODE_SERVER_DIR" remote add origin https://github.com/voiceofhu/one-node-server.git
git -C "$ONE_NODE_SERVER_DIR" config url."file://$backend_bare".insteadOf \
  https://github.com/voiceofhu/one-node-server.git
git -C "$ONE_NODE_SERVER_DIR" push -q -u origin main

printf '%s\n' '{' '  "name": "one-node-web-vite",' '  "version": "0.1.0"' '}' \
  >"$ONE_NODE_WEB_DIR/package.json"
git -C "$ONE_NODE_WEB_DIR" add package.json
git -C "$ONE_NODE_WEB_DIR" commit -qm initial
web_sha="$(git -C "$ONE_NODE_WEB_DIR" rev-parse HEAD)"
git -C "$ONE_NODE_WEB_DIR" remote add origin https://github.com/voiceofhu/one-node-web.git
git -C "$ONE_NODE_WEB_DIR" config url."file://$web_bare".insteadOf \
  https://github.com/voiceofhu/one-node-web.git
git -C "$ONE_NODE_WEB_DIR" push -q -u origin main

mkdir -p "$action_dir/scripts/release" "$action_dir/scripts/github"
cp "$PROJECT_ROOT/scripts/release/deploy-node-server-release.sh" \
  "$action_dir/scripts/release/deploy-node-server-release.sh"
cat >"$action_dir/scripts/github/dispatch-workflow.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$GH_TOKEN" == abcdefghijklmnopqrstuvwxyz123456 ]]
printf '%s\n' "$*" >"$DISPATCH_LOG"
SCRIPT
chmod 0755 "$action_dir/scripts/github/dispatch-workflow.sh"
git -C "$action_dir" add scripts/release/deploy-node-server-release.sh scripts/github/dispatch-workflow.sh
git -C "$action_dir" commit -qm initial
git -C "$action_dir" remote add origin https://github.com/voiceofhu/one-action.git
git -C "$action_dir" config url."file://$action_bare".insteadOf \
  https://github.com/voiceofhu/one-action.git
git -C "$action_dir" push -q -u origin main

bash "$action_dir/scripts/release/deploy-node-server-release.sh" >"$test_dir/output"

if git --git-dir="$backend_bare" show-ref --verify --quiet refs/tags/v26.815.1234 ||
  git --git-dir="$web_bare" show-ref --verify --quiet refs/tags/v26.815.1234; then
  printf '%s\n' 'Node Server trigger created a forbidden source tag.' >&2
  exit 1
fi
node -e '
  const p = require(process.argv[1]);
  if (p.version !== "0.1.0") process.exit(1);
' "$ONE_NODE_WEB_DIR/package.json"

if git --git-dir="$action_bare" for-each-ref --format='%(refname)' refs/tags | grep -q .; then
  printf '%s\n' 'Node Server release created a forbidden Action control tag.' >&2
  exit 1
fi
for field in \
  node-server.yml \
  "backend_ref=$server_sha" \
  "web_ref=$web_sha" \
  version=26.815.1234 \
  publish=true \
  deploy=true; do
  grep -Fq "$field" "$DISPATCH_LOG"
done

require_gate() {
  grep -Fxq "$1" "$LOCAL_GATE_LOG" || {
    printf 'Missing local Node Server gate: %s\n' "$1" >&2
    exit 1
  }
}
require_gate "make --no-print-directory -C $action_dir validate-node-server"
require_gate "make --no-print-directory -C $ONE_NODE_WEB_DIR install lint"
require_gate "make --no-print-directory -C $ONE_NODE_SERVER_DIR test"
require_gate 'go vet ./...'
require_gate "make --no-print-directory -C $ONE_NODE_SERVER_DIR build VERSION=26.815.1234 COMMIT=$server_sha"

printf '%s\n' 'One Node Server dispatched exact source SHAs without repository tags.'
