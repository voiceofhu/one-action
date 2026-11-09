#!/usr/bin/env bash
set -Eeuo pipefail
# One Browser Chromium runtime: local trigger entry, tag parsing, staged
# package verification and the browser-runtime.yml Release contract.
# macOS /bin/bash 3.2 ignores a failed [[ ]] or ! under set -e, so checks say `|| fail`.

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$PROJECT_ROOT/.github/workflows/browser-runtime.yml"
RELEASE_SCRIPT="$PROJECT_ROOT/scripts/release/release-browser-runtime.sh"
ASSETS_SCRIPT="$PROJECT_ROOT/scripts/release/browser-runtime-assets.sh"
CHROMIUM_SHA=0123456789abcdef0123456789abcdef01234567
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_text() {
  local file=$1 text=$2
  grep -Fq -- "$text" "$file" || fail "missing contract in ${file##*/}: $text"
}

job_timeout() {
  awk -v job="$1" '
    $0 == "  " job ":" { inside = 1; next }
    inside && /^  [[:alnum:]_-]+:/ { exit }
    inside && /timeout-minutes:/ { print $2; exit }
  ' "$WORKFLOW"
}

if command -v sha256sum >/dev/null 2>&1; then
  checksum() { sha256sum "$1" | awk '{print $1}'; }
else
  checksum() { shasum -a 256 "$1" | awk '{print $1}'; }
fi

# --- Workflow contract -------------------------------------------------------
require_text "$WORKFLOW" 'name: One Browser Runtime'
require_text "$WORKFLOW" 'tags: ["deploy/browser-runtime/*"]'
require_text "$WORKFLOW" 'read-trigger.sh browser-runtime chromium_ref'
require_text "$WORKFLOW" 'group: one-browser-runtime-${{ github.ref_name }}'
require_text "$WORKFLOW" 'cancel-in-progress: false'
require_text "$WORKFLOW" 'gh release download "runtime-v$VERSION"'
require_text "$WORKFLOW" 'CHROMIUM_REPOSITORY: voiceofhu/one-browser-chromium'
require_text "$WORKFLOW" 'GH_TOKEN: ${{ secrets.GH_TOKEN }}'
require_text "$WORKFLOW" 'bash action/scripts/release/browser-runtime-assets.sh'
require_text "$WORKFLOW" 'release_tag="one-browser-runtime-v$VERSION"'
require_text "$WORKFLOW" 'refusing to mutate it'
require_text "$WORKFLOW" "'.object.type == \"commit\" and .object.sha == \$sha'"
require_text "$WORKFLOW" '--verify-tag'
require_text "$WORKFLOW" '--latest=false'
require_text "$WORKFLOW" '--title "One Browser Runtime $VERSION"'
require_text "$WORKFLOW" '--repo "$GITHUB_REPOSITORY"'
grep -Fq 'workflow_dispatch' "$WORKFLOW" && fail 'Browser Runtime must run only from its deploy tag'
grep -Eq 'gh release (create|upload|edit|delete).*one-browser-chromium' "$WORKFLOW" &&
  fail 'Browser Runtime must not modify the private staging release'
grep -Fq -- '--clobber' "$WORKFLOW" && fail 'Browser Runtime must never overwrite Release assets'
[[ "$(job_timeout prepare)" == 2 ]] || fail 'Browser Runtime source resolution must time out at 2 minutes'
publish_timeout="$(job_timeout publish)"
[[ "$publish_timeout" =~ ^[0-9]+$ ]] && ((publish_timeout <= 30)) ||
  fail 'Browser Runtime publication must time out within 30 minutes'

ruby -ryaml -e '
  workflow = YAML.load_file(ARGV.fetch(0))
  abort "top-level permissions must be contents: read" unless
    workflow["permissions"] == { "contents" => "read" }
  workflow.fetch("jobs").each do |id, job|
    job.fetch("steps", []).each do |step|
      if step["uses"].to_s.start_with?("actions/checkout@")
        abort "#{id}: checkout must not persist credentials" unless
          step.dig("with", "persist-credentials") == false
      end
      next unless step["run"]
      IO.popen(["bash", "-n"], "w") { |io| io.write(step["run"]) }
      abort "#{id}: invalid workflow shell in #{step["name"]}" unless $?.success?
    end
  end
  abort "only publish may write contents" unless
    workflow.dig("jobs", "publish", "permissions") == { "contents" => "write" } &&
    workflow.dig("jobs", "prepare", "permissions").nil?
' "$WORKFLOW" || fail 'Browser Runtime workflow structure'

# --- Local entry -------------------------------------------------------------
require_text "$RELEASE_SCRIPT" 'make --no-print-directory -C "$PROJECT_ROOT" validate-browser-runtime'
require_text "$RELEASE_SCRIPT" 'browser-runtime.yml "$action_sha" "$VERSION" "chromium_ref=$CHROMIUM_REF"'

run_make() {
  make --no-print-directory -s -C "$PROJECT_ROOT" deploy-browser-runtime ENV_FILE=/dev/null "$@"
}
for input in 26.1109.1015 v26.1109.1015; do
  run_make DRY_RUN=true VERSION="$input" CHROMIUM_REF="$CHROMIUM_SHA" >"$test_dir/plan" 2>&1 ||
    fail "dry-run plan failed for VERSION=$input"
  grep -Fq 'staging:  voiceofhu/one-browser-chromium@runtime-v26.1109.1015' "$test_dir/plan" ||
    fail 'plan does not name the staging release'
  grep -Fq "source:   voiceofhu/one-browser-chromium@$CHROMIUM_SHA" "$test_dir/plan" ||
    fail 'plan does not pin chromium_ref'
  grep -Fq 'release:  voiceofhu/one-action@one-browser-runtime-v26.1109.1015' "$test_dir/plan" ||
    fail 'plan does not name the public release'
  grep -Fq 'DRY_RUN=true: no checks ran and no deploy tag was pushed.' "$test_dir/plan" ||
    fail 'dry run did not stop before checks'
done
run_make DRY_RUN=true CHROMIUM_REF="$CHROMIUM_SHA" >/dev/null 2>&1 &&
  fail 'deploy-browser-runtime must require an explicit VERSION'
run_make DRY_RUN=true VERSION=26.01.1 CHROMIUM_REF="$CHROMIUM_SHA" >/dev/null 2>&1 &&
  fail 'deploy-browser-runtime accepted a version with leading zeroes'
for ref in '' main 1111111 "$(tr '[:lower:]' '[:upper:]' <<<"$CHROMIUM_SHA")"; do
  run_make DRY_RUN=true VERSION=26.1109.1015 CHROMIUM_REF="$ref" >/dev/null 2>&1 &&
    fail "deploy-browser-runtime accepted CHROMIUM_REF=$ref"
done

trigger_output="$(DRY_RUN=true bash "$PROJECT_ROOT/scripts/release/trigger.sh" browser-runtime.yml \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 26.1109.1015 "chromium_ref=$CHROMIUM_SHA")" ||
  fail 'trigger dry run failed'
grep -Fq 'Trigger: push tag deploy/browser-runtime/26.1109.1015 at Action aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  <<<"$trigger_output" || fail 'trigger did not plan deploy/browser-runtime/<version>'

# --- read-trigger.sh on a real annotated tag -----------------------------------
git_env=(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid)
"${git_env[@]}" git init -q --bare "$test_dir/origin.git"
"${git_env[@]}" git init -q -b main "$test_dir/work"
"${git_env[@]}" git -C "$test_dir/work" commit -q --allow-empty -m action
"${git_env[@]}" git -C "$test_dir/work" remote add origin "$test_dir/origin.git"
"${git_env[@]}" git -C "$test_dir/work" push -q origin main
action_sha="$(git -C "$test_dir/work" rev-parse HEAD)"

read_tag() {
  local version=$1 message=$2
  "${git_env[@]}" git -C "$test_dir/work" tag -a "deploy/browser-runtime/$version" -m "$message" "$action_sha"
  "${git_env[@]}" git -C "$test_dir/work" push -q origin "refs/tags/deploy/browser-runtime/$version"
  (cd "$test_dir/work" && "${git_env[@]}" GITHUB_REPOSITORY=voiceofhu/one-action GITHUB_REF_TYPE=tag \
    GITHUB_SHA="$action_sha" GITHUB_REF="refs/tags/deploy/browser-runtime/$version" \
    bash "$PROJECT_ROOT/scripts/github/read-trigger.sh" browser-runtime chromium_ref)
}
output="$(read_tag 26.1109.1015 "chromium_ref=$CHROMIUM_SHA" 2>&1)" || fail "read-trigger rejected a valid tag: $output"
[[ "$output" == "version=26.1109.1015"$'\n'"chromium_ref=$CHROMIUM_SHA" ]] ||
  fail "read-trigger printed unexpected outputs: $output"
read_tag 26.1109.1016 "chromium_ref=$CHROMIUM_SHA"$'\n'"src_ref=2222222222222222222222222222222222222222" \
  >/dev/null 2>&1 && fail 'read-trigger must reject pins other than chromium_ref (src_ref is not supported)'
read_tag 26.1109.1017 'chromium_ref=main' >/dev/null 2>&1 && fail 'read-trigger accepted a branch name'

# --- Package verification ------------------------------------------------------
make_package() {
  local dir=$1 platform=$2 arch=$3 asset_version=$4 chromium_version=$5 payload sha
  payload="$(mktemp -d "$test_dir/payload.XXXXXX")"
  printf '%s-%s\n' "$platform" "$arch" >"$payload/Chromium"
  [[ -z "$chromium_version" ]] || printf '%s\n' "$chromium_version" >"$payload/.one-browser-chromium-version"
  if [[ -n "$chromium_version" ]]; then
    COPYFILE_DISABLE=1 tar -czf "$dir/package.tmp" -C "$payload" Chromium .one-browser-chromium-version
  else
    COPYFILE_DISABLE=1 tar -czf "$dir/package.tmp" -C "$payload" Chromium
  fi
  sha="$(checksum "$dir/package.tmp")"
  mv "$dir/package.tmp" "$dir/one-browser-chromium-$platform-$arch-$asset_version-$sha.tar.gz"
  printf '%s\n' "$sha"
}

run_assets() {
  local staging=$1 output=$2
  mkdir -p "$output"
  VERSION=26.1109.1015 CHROMIUM_REF="$CHROMIUM_SHA" \
    bash "$ASSETS_SCRIPT" "$staging" "$output" "$output.notes"
}

case_dir() {
  local dir="$test_dir/case-$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

staging="$(case_dir ok)"
mac_sha="$(make_package "$staging" macos arm64 26.1109.1015 158.0.8127.18)"
win_sha="$(make_package "$staging" windows x64 26.1107.2325 158.0.8127.18)"
run_assets "$staging" "$test_dir/out-ok" >/dev/null || fail 'valid packages were rejected'
[[ -z "$(ls -A "$staging")" ]] || fail 'verified packages must move out of staging'
(cd "$test_dir/out-ok" && { command -v sha256sum >/dev/null && sha256sum --check SHA256SUMS ||
  shasum -a 256 --check SHA256SUMS; } >/dev/null) || fail 'SHA256SUMS does not verify'
[[ "$(wc -l <"$test_dir/out-ok/SHA256SUMS" | tr -d ' ')" == 2 ]] || fail 'SHA256SUMS must list each package'
[[ "$(ls "$test_dir/out-ok" | wc -l | tr -d ' ')" == 3 ]] || fail 'release assets must be packages + SHA256SUMS'
notes="$test_dir/out-ok.notes"
require_text "$notes" 'One Browser Runtime 26.1109.1015'
require_text "$notes" '- Chromium: 158.0.8127.18'
require_text "$notes" "- Source: voiceofhu/one-browser-chromium@$CHROMIUM_SHA"
require_text "$notes" "| macos | arm64 | \`one-browser-chromium-macos-arm64-26.1109.1015-$mac_sha.tar.gz\` |"
require_text "$notes" "| windows | x64 | \`one-browser-chromium-windows-x64-26.1107.2325-$win_sha.tar.gz\` |"
require_text "$notes" "\`$mac_sha\` |"
grep -Eq '\| [0-9]+\.[0-9] MiB \([0-9]+ bytes\) \|' "$notes" || fail 'notes must list package sizes'

expect_reject() {
  local label=$1 staging=$2
  run_assets "$staging" "$test_dir/out-$label" >/dev/null 2>"$test_dir/err-$label" && fail "accepted $label"
  [[ -n "${SHOW_ERRORS:-}" ]] && sed "s/^/$label: /" "$test_dir/err-$label" >&2
  [[ -z "$(ls -A "$test_dir/out-$label")" ]] || fail "$label left partial release assets"
}

expect_reject empty "$(case_dir empty)"

staging="$(case_dir bad-sha)"
sha="$(make_package "$staging" linux x64 26.1109.1015 158.0.8127.18)"
mv "$staging/one-browser-chromium-linux-x64-26.1109.1015-$sha.tar.gz" \
  "$staging/one-browser-chromium-linux-x64-26.1109.1015-$(printf '%064d' 0).tar.gz"
expect_reject bad-sha "$staging"

staging="$(case_dir upper-sha)"
sha="$(make_package "$staging" linux x64 26.1109.1015 158.0.8127.18)"
mv "$staging/one-browser-chromium-linux-x64-26.1109.1015-$sha.tar.gz" \
  "$staging/one-browser-chromium-linux-x64-26.1109.1015-$(tr '[:lower:]' '[:upper:]' <<<"$sha").tar.gz"
expect_reject upper-sha "$staging"

staging="$(case_dir extra)"
make_package "$staging" macos arm64 26.1109.1015 158.0.8127.18 >/dev/null
printf 'x\n' >"$staging/SHA256SUMS"
expect_reject extra "$staging"

staging="$(case_dir platform)"
make_package "$staging" android arm64 26.1109.1015 158.0.8127.18 >/dev/null
expect_reject platform "$staging"

staging="$(case_dir leading-zero)"
make_package "$staging" macos arm64 26.1109.0915 158.0.8127.18 >/dev/null
expect_reject leading-zero "$staging"

staging="$(case_dir duplicate)"
make_package "$staging" macos arm64 26.1109.1015 158.0.8127.18 >/dev/null
make_package "$staging" macos arm64 26.1108.1015 158.0.8127.18 >/dev/null
expect_reject duplicate "$staging"

staging="$(case_dir mixed-chromium)"
make_package "$staging" macos arm64 26.1109.1015 158.0.8127.18 >/dev/null
make_package "$staging" windows x64 26.1109.1015 157.0.8000.1 >/dev/null
expect_reject mixed-chromium "$staging"

staging="$(case_dir no-version)"
make_package "$staging" macos arm64 26.1109.1015 '' >/dev/null
expect_reject no-version "$staging"

staging="$(case_dir subdir)"
make_package "$staging" macos arm64 26.1109.1015 158.0.8127.18 >/dev/null
mkdir "$staging/nested"
expect_reject subdir "$staging"

printf '%s\n' 'One Browser Runtime release contract tests passed.'
