#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
user_workflow="$PROJECT_ROOT/.github/workflows/user.yml"
publisher="$PROJECT_ROOT/.github/workflows/reusable-publish-web-backend.yml"
release="$PROJECT_ROOT/scripts/release/deploy-user-release.sh"

require_text() {
  local file=$1 text=$2
  grep -Fq -- "$text" "$file" || {
    printf 'Missing One User publication contract in %s: %s\n' "${file##*/}" "$text" >&2
    exit 1
  }
}

reject_text() {
  local file=$1 text=$2
  if grep -Fq -- "$text" "$file"; then
    printf 'Unexpected One User publication contract in %s: %s\n' "${file##*/}" "$text" >&2
    exit 1
  fi
}

for file in "$user_workflow" "$publisher" "$release"; do
  [[ -f "$file" ]] || {
    printf 'Missing One User publication file: %s\n' "$file" >&2
    exit 1
  }
done

ruby -ryaml -e '
  user = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
  abort("One User workflow must be tag-only") unless
    user.fetch("on") == {"push" => {"tags" => ["user-v*"]}}
  abort("unexpected One User jobs") unless user.fetch("jobs").keys.sort == %w[prepare publish]
  abort("One User prepare timeout changed") unless
    user.fetch("jobs").fetch("prepare").fetch("timeout-minutes") <= 2

  publisher = YAML.safe_load(File.read(ARGV.fetch(1)), aliases: true)
  matrix = publisher.fetch("jobs").fetch("build").fetch("strategy").fetch("matrix").fetch("include")
  expected = [
    {"arch" => "amd64", "platform" => "linux/amd64", "runner" => "ubuntu-24.04"},
    {"arch" => "arm64", "platform" => "linux/arm64", "runner" => "ubuntu-24.04-arm"}
  ]
  abort("unexpected shared publisher matrix") unless matrix == expected
' "$user_workflow" "$publisher"

for text in \
  'workflow_name: one-user' \
  'backend_sha: ${{ needs.prepare.outputs.backend_sha }}' \
  'web_sha: ${{ needs.prepare.outputs.web_sha }}'; do
  require_text "$user_workflow" "$text"
done

for text in \
  'platforms: ${{ matrix.platform }}' \
  'push: true' \
  'cache-from: type=gha,scope=${{ inputs.workflow_name }}-${{ matrix.arch }}' \
  'cache-to: type=gha,mode=max,scope=${{ inputs.workflow_name }}-${{ matrix.arch }}' \
  'docker buildx imagetools create'; do
  require_text "$publisher" "$text"
done

for text in \
  'make --no-print-directory -C "$PROJECT_ROOT" validate-user' \
  'cargo fmt --all -- --check' \
  'make --no-print-directory -C "$ONE_USER_BACKEND_DIR" test' \
  'pnpm --dir "$ONE_USER_WEB_DIR" install --frozen-lockfile' \
  'pnpm --dir "$ONE_USER_WEB_DIR" format:check' \
  'pnpm --dir "$ONE_USER_WEB_DIR" lint' \
  'pnpm --dir "$ONE_USER_WEB_DIR" test' \
  'pnpm --dir "$ONE_USER_WEB_DIR" build'; do
  require_text "$release" "$text"
done

if grep -Fxq 'make --no-print-directory -C "$PROJECT_ROOT" validate' "$release"; then
  printf '%s\n' 'One User release must not invoke the full validation scope.' >&2
  exit 1
fi
reject_text "$release" 'make --no-print-directory -C "$ONE_USER_BACKEND_DIR" check'
reject_text "$release" 'make --no-print-directory -C "$ONE_USER_BACKEND_DIR" build'

printf '%s\n' 'One User focused publication workflow contract passed.'
