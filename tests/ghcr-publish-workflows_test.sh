#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
publisher="$PROJECT_ROOT/.github/workflows/reusable-publish-server-image.yml"
product_server="$PROJECT_ROOT/.github/workflows/reusable-deploy-server.yml"

require_text() {
  local file=$1 text=$2
  grep -Fq -- "$text" "$file" || {
    printf 'Missing publication contract in %s: %s\n' "$file" "$text" >&2
    exit 1
  }
}

reject_text() {
  local file=$1 text=$2
  if grep -Fiq -- "$text" "$file"; then
    printf 'Forbidden publication workflow content in %s: %s\n' "$file" "$text" >&2
    exit 1
  fi
}

assert_jobs() {
  local file=$1 expected=$2
  ruby -ryaml -e '
    workflow = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
    actual = workflow.fetch("jobs").keys.sort.join(",")
    abort("unexpected jobs: #{actual}") unless actual == ARGV.fetch(1)
  ' "$file" "$expected"
}

assert_timeout_at_most() {
  local file=$1 job=$2 maximum=$3
  ruby -ryaml -e '
    workflow = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
    timeout = workflow.fetch("jobs").fetch(ARGV.fetch(1)).fetch("timeout-minutes")
    maximum = Integer(ARGV.fetch(2), 10)
    abort("timeout must be a positive integer at most #{maximum}") unless
      timeout.is_a?(Integer) && timeout.positive? && timeout <= maximum
  ' "$file" "$job" "$maximum"
}

assert_native_matrix() {
  local file=$1
  ruby -ryaml -e '
    workflow = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
    actual = workflow.fetch("jobs").fetch("build").fetch("strategy").fetch("matrix").fetch("include")
    expected = [
      {"arch" => "amd64", "platform" => "linux/amd64", "runner" => "ubuntu-24.04"},
      {"arch" => "arm64", "platform" => "linux/arm64", "runner" => "ubuntu-24.04-arm"}
    ]
    abort("build matrix must contain only the two native Linux architectures") unless actual == expected
  ' "$file"
}

for file in "$publisher" "$product_server"; do
  [[ -f "$file" ]] || {
    printf 'Required publication contract file is missing: %s\n' "$file" >&2
    exit 1
  }
done

assert_jobs "$publisher" 'build,manifest'
assert_timeout_at_most "$product_server" prepare 2
assert_timeout_at_most "$publisher" build 20
assert_timeout_at_most "$publisher" manifest 3
assert_native_matrix "$publisher"

require_text "$product_server" 'timeout-minutes: 2'
require_text "$product_server" '&& "$ACTION_SHA" == "$EXPECTED_ACTION_SHA"'
require_text "$product_server" 'backend_pid=$!'
require_text "$product_server" 'web_pid=$!'
require_text "$product_server" 'wait "$backend_pid"'
require_text "$product_server" 'wait "$web_pid"'
require_text "$product_server" "created_at=\"\$(jq -er '.commit.committer.date' \"\$web_commit_file\")\""
require_text "$product_server" 'uses: ./.github/workflows/reusable-publish-server-image.yml'
require_text "$product_server" 'contents: read'
require_text "$product_server" 'packages: write'
require_text "$product_server" 'source_read_token: ${{ secrets.GH_TOKEN }}'
require_text "$product_server" 'package_write_token: ${{ secrets.GH_TOKEN }}'

require_text "$publisher" 'repository: ${{ inputs.backend_repository }}'
require_text "$publisher" 'repository: ${{ inputs.web_repository }}'
require_text "$publisher" 'version: ${{ inputs.pnpm_version }}'
require_text "$publisher" 'file: backend/${{ inputs.dockerfile }}'
require_text "$publisher" 'org.opencontainers.image.source=https://github.com/${{ inputs.backend_repository }}'
reject_text "$publisher" "inputs.workflow_name =="
require_text "$publisher" 'ref: ${{ inputs.backend_sha }}'
require_text "$publisher" 'ref: ${{ inputs.web_sha }}'
require_text "$publisher" 'token: ${{ secrets.source_read_token }}'
require_text "$publisher" 'persist-credentials: false'
require_text "$publisher" 'runner: ubuntu-24.04'
require_text "$publisher" 'runner: ubuntu-24.04-arm'
require_text "$publisher" 'platform: linux/amd64'
require_text "$publisher" 'platform: linux/arm64'
require_text "$publisher" 'pnpm --dir web install --frozen-lockfile'
require_text "$publisher" 'pnpm --dir web build'
require_text "$publisher" 'mkdir backend/web-dist'
require_text "$publisher" 'cp -R web/dist/. backend/web-dist/'
reject_text "$publisher" 'web/out'
require_text "$publisher" 'uses: docker/build-push-action@'
require_text "$publisher" 'platforms: ${{ matrix.platform }}'
require_text "$publisher" 'push: true'
require_text "$publisher" ':build-${{ inputs.backend_sha }}-${{ inputs.web_sha }}-${{ github.run_id }}-${{ github.run_attempt }}-${{ matrix.arch }}'
require_text "$publisher" 'org.opencontainers.image.revision=${{ inputs.backend_sha }}'
require_text "$publisher" 'org.opencontainers.image.version=${{ inputs.version }}'
require_text "$publisher" 'one.action.revision=${{ inputs.action_sha }}'
require_text "$publisher" 'one.web.revision=${{ inputs.web_sha }}'
require_text "$publisher" 'provenance: false'
require_text "$publisher" 'sbom: false'
require_text "$publisher" 'needs: build'
require_text "$publisher" 'docker buildx imagetools create'
require_text "$publisher" '"$candidate-amd64"'
require_text "$publisher" '"$candidate-arm64"'
require_text "$publisher" 'candidate_fingerprint="$(fingerprint "$candidate")"'
require_text "$publisher" 'index:one.action.revision=$ACTION_SHA'
require_text "$publisher" 'index:org.opencontainers.image.revision=$BACKEND_SHA'
require_text "$publisher" 'index:one.web.revision=$WEB_SHA'
require_text "$publisher" "--format '{{json .Manifest}}' | jq -r '.digest'"
require_text "$publisher" "printf 'digest=%s\\n' \"\$digest\""
require_text "$publisher" "printf 'image_ref=%s@%s\\n' \"\$image\" \"\$digest\""
require_text "$publisher" 'value: ${{ jobs.manifest.outputs.digest }}'
require_text "$publisher" 'value: ${{ jobs.manifest.outputs.image_ref }}'
require_text "$publisher" 'login=$(gh api user --jq .login)'
reject_text "$publisher" 'username: ${{ github.actor }}'

reject_text "$publisher" '  deploy:'
reject_text "$publisher" 'scripts/deploy/'
reject_text "$publisher" 'ssh'

for workflow in "$product_server" "$publisher"; do
  reject_text "$workflow" 'cargo test'
  reject_text "$workflow" 'go test'
  reject_text "$workflow" 'make test'
  reject_text "$workflow" 'pnpm --dir web test'
  reject_text "$workflow" 'lint'
  reject_text "$workflow" 'actions/cache'
  reject_text "$workflow" 'upload-artifact'
  reject_text "$workflow" 'download-artifact'
done

require_text "$publisher" 'cache-from: type=gha,scope=${{ inputs.workflow_name }}-${{ matrix.arch }}'
require_text "$publisher" 'cache-to: type=gha,mode=max,scope=${{ inputs.workflow_name }}-${{ matrix.arch }}'

printf '%s\n' 'Active GHCR publication workflow contracts passed.'
