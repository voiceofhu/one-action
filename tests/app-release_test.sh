#!/usr/bin/env bash
set -Eeuo pipefail
# Runs the shared Tauri release entry and workflow scripts for one apps.json
# client (default: every client).
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -eq 0 ]]; then
  for app in $(jq -r 'keys[]' "$PROJECT_ROOT/apps.json"); do
    bash "${BASH_SOURCE[0]}" "$app"
  done
  exit 0
fi
# shellcheck source=scripts/lib/app.sh
source "$PROJECT_ROOT/scripts/lib/app.sh"
load_app "$1"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

for input in '' v26.907.101; do
  expected=${input#v}
  expected=${expected:-26.906.1234}
  make --no-print-directory -s -C "$PROJECT_ROOT" "deploy-$APP_KEY-app" \
    ENV_FILE=/dev/null DRY_RUN=true VERSION="$input" GENERATED_VERSION=26.906.1234 \
    >"$test_dir/plan" 2>&1
  grep -Fq "$APP_RELEASE_PREFIX-v$expected from $APP_REPOSITORY branch main (tag deploy/$APP_KEY-app/$expected)" \
    "$test_dir/plan"
  grep -Fq 'DRY_RUN=true: no checks ran and no deploy tag was pushed.' "$test_dir/plan"
  if [[ -n "$APP_BACKEND_REPOSITORY" ]]; then
    grep -Fq "Shared backend: $APP_BACKEND_REPOSITORY branch main" "$test_dir/plan"
  fi
done

ruby -ryaml -e '
  workflow = YAML.load_file(ARGV.fetch(0))
  workflow.fetch("jobs").each_value do |job|
    job.fetch("steps", []).each do |step|
      next unless step["run"]
      IO.popen(["bash", "-n"], "w") { |io| io.write(step["run"]) }
      abort "invalid workflow shell" unless $?.success?
    end
  end
  prepare = workflow.fetch("jobs").fetch("prepare").fetch("steps").find { |s| s["id"] == "release" }
  File.write("#{ARGV[1]}/prepare.sh", prepare.fetch("run"))
  plan = workflow.fetch("jobs").fetch("prepare").fetch("steps").find { |s| s["id"] == "plan" }
  File.write("#{ARGV[1]}/plan.sh", plan.fetch("run"))
  pnpm = workflow.fetch("jobs").fetch("prepare").fetch("steps").find { |s| s["id"] == "pnpm" }
  File.write("#{ARGV[1]}/pnpm.sh", pnpm.fetch("run"))
  build = workflow.fetch("jobs").fetch("build")
  abort "build matrix must come from the platform plan" unless
    build.dig("strategy", "matrix") == "${{ fromJSON(needs.prepare.outputs.matrix) }}"
  steps = build.fetch("steps")
  backend = steps.find { |s| s["name"] == "Checkout exact Backend source" }
  abort "backend checkout must pin backend_sha at ../backend of the App" unless backend &&
    backend.dig("with", "path") == "backend" &&
    backend.dig("with", "ref") == "${{ needs.prepare.outputs.backend_sha }}" &&
    backend["if"] == "needs.prepare.outputs.backend_repository != \u0027\u0027"
  # pnpm 11 cannot run natively on Intel macOS (pnpm/pnpm#11423).
  native = steps.find { |s| s["name"] == "Set up native pnpm" }
  npm_pnpm = steps.find { |s| s["name"] == "Set up pnpm from npm" }
  # The runner decides, as an App may cross-build macos-amd64 on Apple Silicon.
  abort "Intel macOS must install pnpm 11 from npm" unless
    native && native["if"].include?("(runner.os != \u0027macOS\u0027 || runner.arch != \u0027X64\u0027)") &&
    npm_pnpm && npm_pnpm["if"].include?("runner.os == \u0027macOS\u0027 && runner.arch == \u0027X64\u0027")
  stamp = steps.find { |s| s["name"] == "Set App release version" }
  abort "version input missing" unless stamp.dig("env", "VERSION") == "${{ needs.prepare.outputs.version }}"
  abort "stamp must precede bundle" unless steps.index(stamp) < steps.index(steps.find { |s| s["name"] == "Build desktop bundle" })
  File.write("#{ARGV[1]}/stamp.sh", stamp.fetch("run"))
  publish = workflow.fetch("jobs").fetch("publish").fetch("steps").find { |s| s["name"] == "Publish release assets" }
  abort "immutable release guard removed" unless publish.fetch("run").include?("refusing to mutate it")
  File.write("#{ARGV[1]}/publish.sh", publish.fetch("run"))
  caller = YAML.load_file(ARGV.fetch(2))
  release = caller.fetch("jobs").fetch("release")
  abort "#{ARGV[2]} must call the shared Tauri publisher" unless
    release.fetch("uses") == "./.github/workflows/reusable-publish-tauri-app.yml" &&
    release.fetch("with").fetch("app") == ARGV.fetch(3) &&
    release.fetch("permissions") == { "contents" => "write" }
' "$PROJECT_ROOT/.github/workflows/reusable-publish-tauri-app.yml" "$test_dir" \
  "$PROJECT_ROOT/.github/workflows/$APP_WORKFLOW" "$APP_KEY"

mkdir -p "$test_dir/bin" "$test_dir/app/scripts"
cat >"$test_dir/bin/gh" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$API_LOG"
case "$2" in
  */releases/tags/*)
    case "$RELEASE_STATE" in
      missing) printf '%s\n' '{"status":"404"}'; exit 1 ;;
      exists) printf '%s\n' '{"id":1}' ;;
      denied) printf '%s\n' '{"status":"403"}'; exit 1 ;;
      transport) exit 1 ;;
    esac ;;
  */commits/*) printf '{"sha":"%s"}\n' "${2##*/}" ;;
  *) exit 99 ;;
esac
SCRIPT
chmod +x "$test_dir/bin/gh"
export PATH="$test_dir/bin:$PATH"
export RUNNER_TEMP="$test_dir" GITHUB_OUTPUT="$test_dir/output" API_LOG="$test_dir/api"
export ACTION_REPOSITORY=voiceofhu/one-action ACTION_SERVER_URL=https://github.com
export ACTION_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export CALLER_WORKFLOW="voiceofhu/one-action/.github/workflows/$APP_WORKFLOW@refs/tags/deploy/$APP_KEY-app/26.906.1234"
export APP_KEY APP_TITLE APP_REPOSITORY RELEASE_PREFIX="$APP_RELEASE_PREFIX"
export APP_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb VERSION=26.906.1234
export GH_TOKEN=fixture-token
export WEB_REPOSITORY="$APP_WEB_REPOSITORY" WEB_SHA=
[[ -z "$WEB_REPOSITORY" ]] || WEB_SHA=cccccccccccccccccccccccccccccccccccccccc
export BACKEND_REPOSITORY="$APP_BACKEND_REPOSITORY" BACKEND_SHA=
[[ -z "$BACKEND_REPOSITORY" ]] || BACKEND_SHA=dddddddddddddddddddddddddddddddddddddddd

# pnpm installer: native pnpm/setup from pnpm 11, pnpm/action-setup before.
for case in "11.7.0 true" "12.0.1 true" "10.32.1 false" "9.15.0 false"; do
  : >"$GITHUB_OUTPUT"
  PNPM_VERSION="${case% *}" bash "$test_dir/pnpm.sh"
  [[ "$(cat "$GITHUB_OUTPUT")" == "native=${case#* }" ]] || {
    printf 'pnpm %s chose %s\n' "${case% *}" "$(cat "$GITHUB_OUTPUT")" >&2
    exit 1
  }
done
: >"$GITHUB_OUTPUT"

# Platform plan: the App's platforms (default all four) on the App's runner
# overrides, unknown names rejected.
PLATFORMS="$APP_PLATFORMS" RUNNERS="$APP_RUNNERS" bash "$test_dir/plan.sh"
expected_platforms="$(jq -c '. // ["linux-amd64","windows-amd64","macos-arm64","macos-amd64"]' <<<"$APP_PLATFORMS")"
[[ "$(sed -n 's/^matrix=//p' "$GITHUB_OUTPUT" | jq -c '[.include[].name]')" == "$expected_platforms" ]]
sed -n 's/^matrix=//p' "$GITHUB_OUTPUT" | jq -e '.include | all(.runner != "" and .bundles != "" and .assets != "")' >/dev/null
sed -n 's/^matrix=//p' "$GITHUB_OUTPUT" |
  jq -e --argjson runners "$APP_RUNNERS" '.include | all(.runner == ($runners[.name] // .runner))' >/dev/null
plan_rejects() {
  : >"$GITHUB_OUTPUT"
  if PLATFORMS="$1" RUNNERS="$2" bash "$test_dir/plan.sh" >/dev/null 2>&1; then
    printf 'platform plan accepted an unknown platform: %s %s\n' "$1" "$2" >&2
    exit 1
  fi
}
plan_rejects '["macos-arm64","solaris-sparc"]' '{}'
plan_rejects null '{"solaris-sparc":"macos-15"}'
: >"$GITHUB_OUTPUT"

bad_inputs=(CALLER_WORKFLOW APP_SHA VERSION)
[[ -z "$WEB_REPOSITORY" ]] || bad_inputs+=(WEB_SHA)
[[ -z "$BACKEND_REPOSITORY" ]] || bad_inputs+=(BACKEND_SHA)
for bad in "${bad_inputs[@]}"; do
  export RELEASE_STATE=missing
  : >"$GITHUB_OUTPUT"
  if env "$bad=wrong" bash "$test_dir/prepare.sh" >/dev/null 2>&1; then
    printf '%s accepted a wrong %s\n' "$APP_WORKFLOW" "$bad" >&2
    exit 1
  fi
done
for state in missing exists denied transport; do
  export RELEASE_STATE="$state"
  : >"$GITHUB_OUTPUT"
  : >"$API_LOG"
  if bash "$test_dir/prepare.sh" >"$test_dir/stdout" 2>"$test_dir/stderr"; then
    [[ "$state" == missing ]]
    grep -q "release_tag=$APP_RELEASE_PREFIX-v26.906.1234" "$GITHUB_OUTPUT"
    if [[ -n "$WEB_REPOSITORY" ]]; then
      grep -q "web_sha=$WEB_SHA" "$GITHUB_OUTPUT"
      grep -q "repos/$WEB_REPOSITORY/commits/$WEB_SHA" "$API_LOG"
    else
      ! grep -q web_sha "$GITHUB_OUTPUT"
    fi
    if [[ -n "$BACKEND_REPOSITORY" ]]; then
      grep -q "backend_sha=$BACKEND_SHA" "$GITHUB_OUTPUT"
      grep -q "repos/$BACKEND_REPOSITORY/commits/$BACKEND_SHA" "$API_LOG"
    else
      ! grep -q backend_sha "$GITHUB_OUTPUT"
    fi
  else
    [[ "$state" != missing ]]
    [[ ! -s "$GITHUB_OUTPUT" ]]
    ! grep -q '/commits/' "$API_LOG"
  fi
done

# Model the source-owned updater to verify the workflow passes VERSION in the App cwd.
printf '%s\n' '{"version":"26.804.15"}' >"$test_dir/app/package.json"
cat >"$test_dir/app/scripts/update-version.mjs" <<'SCRIPT'
import fs from 'node:fs';
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
pkg.version = process.argv[2];
fs.writeFileSync('package.json', JSON.stringify(pkg));
SCRIPT
(cd "$test_dir" && bash stamp.sh)
node -e 'if (require(process.argv[1]).version !== process.argv[2]) process.exit(1)' \
  "$test_dir/app/package.json" "$VERSION"

cat >"$test_dir/bin/gh" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$API_LOG"
case "$1 $2" in
  'release view') exit 1 ;;
  'release create')
    [[ " $* " == *' --verify-tag '* && " $* " == *' --latest=false '* ]]
    [[ "$3" == "$RELEASE_TAG" ]]
    ;;
  'api --method')
    [[ "$*" == *"ref=refs/tags/$RELEASE_TAG"* && "$*" == *"sha=$GITHUB_SHA"* ]]
    touch "$TAG_CREATED"
    printf '{"object":{"type":"commit","sha":"%s"}}\n' "$GITHUB_SHA"
    ;;
  api*)
    if [[ "$TAG_STATE" == denied ]]; then
      printf '%s\n' '{"status":"403"}'; exit 1
    elif [[ "$TAG_STATE" == transport ]]; then
      exit 1
    elif [[ "$TAG_STATE" == missing && ! -f "$TAG_CREATED" ]]; then
      printf '%s\n' '{"status":"404"}'; exit 1
    elif [[ "$TAG_STATE" == mismatch ]]; then
      printf '{"object":{"type":"commit","sha":"%s"}}\n' "$APP_SHA"
    else
      printf '{"object":{"type":"commit","sha":"%s"}}\n' "$GITHUB_SHA"
    fi
    ;;
  *) exit 99 ;;
esac
SCRIPT
export GITHUB_REPOSITORY=voiceofhu/one-action GITHUB_SHA="$ACTION_SHA"
export RELEASE_TAG="$APP_RELEASE_PREFIX-v$VERSION" TAG_CREATED="$test_dir/tag-created"
for state in missing matching mismatch denied transport; do
  export TAG_STATE="$state"
  rm -f "$TAG_CREATED"
  : >"$API_LOG"
  work="$test_dir/publish-$state"
  mkdir -p "$work/dist/$APP_RELEASE_PREFIX-macos-arm64"
  printf 'fixture' >"$work/dist/$APP_RELEASE_PREFIX-macos-arm64/app.dmg"
  if (cd "$work" && bash "$test_dir/publish.sh") >"$test_dir/stdout" 2>"$test_dir/stderr"; then
    [[ "$state" == missing || "$state" == matching ]]
    grep -q '^release create ' "$API_LOG"
    if [[ "$state" == missing ]]; then
      [[ -f "$TAG_CREATED" ]]
    else
      [[ ! -f "$TAG_CREATED" ]]
    fi
  else
    [[ "$state" != missing && "$state" != matching ]]
    [[ ! -f "$TAG_CREATED" ]]
    ! grep -q '^release create ' "$API_LOG"
  fi
done
printf '%s version, platform plan, CI stamping, duplicate guards and immutable tag publication tests passed.\n' "$APP_TITLE"
