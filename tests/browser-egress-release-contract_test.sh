#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$PROJECT_ROOT/.github/workflows/egress.yml"
RELEASE_SCRIPT="$PROJECT_ROOT/scripts/release/deploy-browser-egress-release.sh"
INSTALLER="$PROJECT_ROOT/egress/install.sh"
UPDATER="$PROJECT_ROOT/egress/scripts/install/updater.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_text() {
  local file=$1 text=$2
  grep -Fq -- "$text" "$file" || fail "missing contract in ${file##*/}: $text"
}

line_number() {
  local file=$1 text=$2 matches count
  matches="$(grep -nF -- "$text" "$file")" || fail "missing ordered contract: $text"
  count="$(printf '%s\n' "$matches" | wc -l | tr -d '[:space:]')"
  [[ "$count" == 1 ]] || fail "ordered contract must occur once: $text"
  printf '%s\n' "${matches%%:*}"
}

require_text "$PROJECT_ROOT/make/browser.mk" 'deploy-browser-egress:'
if grep -Fq -- 'deploy-app-egress' "$PROJECT_ROOT/make/browser.mk"; then
  fail 'Legacy deploy-app-egress target must be removed'
fi
require_text "$PROJECT_ROOT/make/config.mk" 'BROWSER_EGRESS_RELEASE_VERSION ='
require_text "$PROJECT_ROOT/make/config.mk" '$(GENERATED_VERSION)'

require_text "$RELEASE_SCRIPT" 'release_tag="one-browser-egress-v$VERSION"'
require_text "$RELEASE_SCRIPT" 'unset GH_TOKEN GITHUB_TOKEN CONFIRM_DISPATCH CONFIRM_MUTATION'
require_text "$RELEASE_SCRIPT" 'make --no-print-directory -C "$PROJECT_ROOT" validate-browser-egress'
require_text "$RELEASE_SCRIPT" 'cargo fmt --manifest-path "$ONE_BROWSER_EGRESS_DIR/Cargo.toml" --all --check'
require_text "$RELEASE_SCRIPT" 'cargo clippy --manifest-path "$ONE_BROWSER_EGRESS_DIR/Cargo.toml"'
require_text "$RELEASE_SCRIPT" 'cargo test --manifest-path "$ONE_BROWSER_EGRESS_DIR/Cargo.toml"'
require_text "$RELEASE_SCRIPT" 'bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" egress.yml'
require_text "$RELEASE_SCRIPT" '"egress_ref=$egress_ref"'

test_line="$(line_number "$RELEASE_SCRIPT" 'cargo test --manifest-path "$ONE_BROWSER_EGRESS_DIR/Cargo.toml"')"
dispatch_line="$(line_number "$RELEASE_SCRIPT" 'bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" egress.yml')"
((test_line < dispatch_line)) || fail 'Egress tests must finish before workflow dispatch'

if grep -Fq -- 'git -C "$PROJECT_ROOT" tag' "$RELEASE_SCRIPT" ||
  grep -Fq -- 'git -C "$ONE_BROWSER_EGRESS_DIR" tag' "$RELEASE_SCRIPT"; then
  fail 'Local Browser Egress release must not create repository tags'
fi

require_text "$WORKFLOW" 'egress_repository: {required: true, type: string}'
require_text "$WORKFLOW" 'egress_ref: {required: true, type: string}'
require_text "$WORKFLOW" 'repository: voiceofhu/one-browser-egress'
require_text "$WORKFLOW" '  build:'
require_text "$WORKFLOW" 'name: Build and upload linux/${{ matrix.arch }}'
require_text "$WORKFLOW" 'file: egress/Dockerfile'
require_text "$WORKFLOW" 'working-directory: egress'
require_text "$WORKFLOW" 'toolchain="$(sed -nE'
require_text "$WORKFLOW" 'rustup toolchain install "$toolchain"'
require_text "$WORKFLOW" '--target "$RUST_TARGET"'
require_text "$WORKFLOW" 'RUSTUP_TOOLCHAIN=%s'
require_text "$WORKFLOW" 'rustup target list --installed | grep -Fx "$RUST_TARGET"'
require_text "$WORKFLOW" 'one-browser-egress-linux-amd64 one-browser-egress-linux-arm64 >SHA256SUMS'
require_text "$WORKFLOW" 'ghcr.io/voiceofhu/one-browser-egress:'
require_text "$WORKFLOW" 'gh release create "$RELEASE_TAG"'
require_text "$INSTALLER" 'updater.sh'
require_text "$INSTALLER" '--upgrade-existing'
require_text "$UPDATER" 'one-browser-egress-updater.service'
require_text "$UPDATER" 'one-browser-egress-updater.path'
require_text "$UPDATER" '"$install_dir/install.sh" --upgrade "$version"'
require_text "$PROJECT_ROOT/egress/scripts/install/enrollment.sh" 'EGRESS_UPGRADE_REQUEST_FILE='
require_text "$PROJECT_ROOT/egress/scripts/install/compose-config.sh" ':/app/update'

upgrade_parse_output="$(
  ONE_BROWSER_INSTALLER_LIBRARY_ONLY=1 bash -c '
    source "$1"
    upgrade_existing_installation() { printf "upgrade:%s\n" "$1"; }
    bootstrap --upgrade-existing --version 26.902.1200
  ' _ "$INSTALLER"
)"
[[ "$upgrade_parse_output" == 'upgrade:26.902.1200' ]] ||
  fail 'Egress installer did not route tokenless managed upgrade safely'
if grep -Eq '^  (native|image):' "$WORKFLOW"; then
  fail 'Browser Egress must use one build matrix for native assets and images'
fi
if grep -Fq -- 'dtolnay/rust-toolchain@stable' "$WORKFLOW"; then
  fail 'Browser Egress must not install the musl target on a different stable toolchain'
fi
if grep -Fq -- 'egress/deploy/docker/Dockerfile' "$WORKFLOW"; then
  fail 'Browser Egress workflow references the removed nested Dockerfile path'
fi
[[ "$(grep -Ec '^[[:space:]]+- arch: (amd64|arm64)$' "$WORKFLOW")" == 2 ]] ||
  fail 'Browser Egress build matrix must contain exactly amd64 and arm64'
[[ "$(grep -Fc -- '- build' "$WORKFLOW")" == 2 ]] ||
  fail 'Browser Egress Release and image manifest must both depend on build'

dry_run_output="$(
  DRY_RUN=true \
  VERSION=26.901.1200 \
  ONE_BROWSER_EGRESS_DIR=/missing/one-browser-egress \
  ONE_BROWSER_EGRESS_REPOSITORY=voiceofhu/one-browser-egress \
  bash "$RELEASE_SCRIPT"
)"
grep -Fq 'One Browser Egress release plan:' <<<"$dry_run_output" ||
  fail 'Browser Egress dry-run did not print the release plan'
grep -Fq 'DRY_RUN=true:' <<<"$dry_run_output" ||
  fail 'Browser Egress dry-run did not stop before repository or API access'

dispatch_fixture="$(mktemp -d)"
trap 'rm -rf "$dispatch_fixture"' EXIT
ln -s "$PROJECT_ROOT/tests/fakes/curl" "$dispatch_fixture/curl"
: >"$dispatch_fixture/curl.log"
dispatch_output="$(
  PATH="$dispatch_fixture:$PATH" \
  GH_TOKEN=abcdefghijklmnopqrstuvwxyz123456 \
  FAKE_EXPECTED_AUTH=abcdefghijklmnopqrstuvwxyz123456 \
  FAKE_CURL_LOG="$dispatch_fixture/curl.log" \
  DRY_RUN=true \
  ACTION_REPOSITORY=voiceofhu/one-action \
  ACTION_REF=main \
  bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" egress.yml \
    egress_repository=voiceofhu/one-browser-egress \
    egress_ref=main \
    version=26.901.1200 \
    environment=prod \
    publish=true \
    deploy=false
)"
grep -Fq '"egress_ref": "2222222222222222222222222222222222222222"' <<<"$dispatch_output" ||
  fail 'Browser Egress dispatch did not pin the exact source commit'
grep -Fq '"confirmation": "enable:egress:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' <<<"$dispatch_output" ||
  fail 'Browser Egress dispatch did not carry the publication confirmation'

printf '%s\n' 'One Browser Egress release contract tests passed.'

# Exercise the persisted manager without touching host services or the network.
ONE_BROWSER_INSTALLER_LIBRARY_ONLY=1 bash -s -- "$INSTALLER" <<'TEST'
set -Eeuo pipefail
source "$1"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
INSTALL_DIR=$fixture
INSTALL_RECORD=$fixture/.installation
printf 'schema=2\nruntime=native\nversion=26.902.1000\n' >"$INSTALL_RECORD"
chown() { :; }
install_manager
bash -n "$fixture/install.sh"
# Load the generated functions while suppressing its final manager invocation.
source <(sed '$d' "$fixture/install.sh")
systemctl() { printf 'active\n'; }
[[ "$(manager_action --status)" == *'version: 26.902.1000'* ]]
manager_run_entrypoint() { printf '%s\n' "$*"; }
[[ "$(manager_action --upgrade 26.902.1200)" == 'install.sh --upgrade-existing --version 26.902.1200' ]]
[[ "$(manager_action --upgrade)" == 'install.sh --upgrade-existing --version latest' ]]
if (manager_action --upgrade invalid) >/dev/null 2>&1; then exit 1; fi
[[ "$(printf '4\n26.902.1200\n0\n' | manager_interactive)" == *'install.sh --upgrade-existing --version 26.902.1200'* ]]
[[ "$(printf '8\nn\n0\n' | manager_interactive)" != *'uninstall.sh --mode'* ]]
[[ "$(printf '8\ny\n' | manager_interactive)" == *'uninstall.sh --mode native'* ]]
manager_main() { printf 'manager:%s\n' "$*"; }
[[ "$(bootstrap --upgrade 26.902.1200)" == 'manager:--upgrade 26.902.1200' ]]
TEST
printf '%s\n' 'Egress persisted manager tests passed.'

# Recreate the function payload passed to the isolated second-stage Bash.
ONE_BROWSER_INSTALLER_LIBRARY_ONLY=1 bash -s -- "$INSTALLER" <<'TEST'
set -Eeuo pipefail
source "$1"
eval "$(sed -n '/^  stage_code=$(declare -f /,/installer_main)/p' "${1%/install.sh}/scripts/install/main.sh")"
for existing in docker native; do
  if [ "$existing" = docker ]; then requested=native; else requested=docker; fi
  status=0
  output=$(bash -c "${stage_code}"$'\n''die_runtime_switch "$@"' stage2 "$existing" "$requested" 2>&1) || status=$?
  [[ "$status" = 1 ]]
  [[ "$output" == *"installed in $existing mode; uninstall it before switching to $requested mode."* ]]
  [[ "$output" == *'https://raw.githubusercontent.com/voiceofhu/one-action/main/egress/uninstall.sh'* ]]
  [[ "$output" != *'command not found'* ]]
done
TEST
printf '%s\n' 'Egress second-stage runtime switch tests passed.'

require_text "$UPDATER" 'Restart=on-failure'
require_text "$UPDATER" 'systemctl enable one-browser-egress-updater.service'
