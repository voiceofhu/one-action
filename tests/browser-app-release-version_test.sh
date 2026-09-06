#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

for input in '' v26.907.101; do
  expected=${input#v}
  expected=${expected:-26.906.1234}
  make --no-print-directory -s -C "$PROJECT_ROOT" deploy-browser-app \
    ENV_FILE=/dev/null DRY_RUN=true VERSION="$input" GENERATED_VERSION=26.906.1234 \
    >"$test_dir/plan"
  sed '/DRY_RUN=true:/,$d' "$test_dir/plan" | \
    jq -e --arg version "$expected" '.inputs.version == $version and .inputs.publish == true' >/dev/null
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
  build = workflow.fetch("jobs").fetch("build")
  steps = build.fetch("steps")
  stamp = steps.find { |s| s["name"] == "Set App release version" }
  abort "version input missing" unless stamp.dig("env", "VERSION") == "${{ inputs.version }}"
  abort "stamp must precede bundle" unless steps.index(stamp) < steps.index(steps.find { |s| s["name"] == "Build desktop bundle" })
  File.write("#{ARGV[1]}/stamp.sh", stamp.fetch("run"))
  publish = workflow.fetch("jobs").fetch("publish").fetch("steps").find { |s| s["name"] == "Publish release assets" }
  abort "immutable release guard removed" unless publish.fetch("run").include?("refusing to mutate it")
' "$PROJECT_ROOT/.github/workflows/app.yml" "$test_dir"

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
  */commits/*) printf '{"sha":"%s"}\n' "$APP_REF" ;;
  *) exit 99 ;;
esac
SCRIPT
chmod +x "$test_dir/bin/gh"
export PATH="$test_dir/bin:$PATH"
export RUNNER_TEMP="$test_dir" GITHUB_OUTPUT="$test_dir/output" API_LOG="$test_dir/api"
export ACTION_REPOSITORY=voiceofhu/one-action ACTION_SERVER_URL=https://github.com
export ACTION_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa EXPECTED_ACTION_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export CONFIRMATION="enable:app:$ACTION_SHA" APP_REPOSITORY=voiceofhu/one-browser-app
export APP_REF=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb VERSION=26.906.1234 PUBLISH=true
export GH_TOKEN=fixture-token

for state in missing exists denied transport; do
  export RELEASE_STATE="$state"
  : >"$GITHUB_OUTPUT"
  : >"$API_LOG"
  if bash "$test_dir/prepare.sh" >"$test_dir/stdout" 2>"$test_dir/stderr"; then
    [[ "$state" == missing ]]
    grep -q 'release_tag=one-browser-app-v26.906.1234' "$GITHUB_OUTPUT"
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
printf '%s\n' 'Browser App generated/explicit versions, CI stamping and early duplicate/error guards passed.'
