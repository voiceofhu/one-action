#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
prepare="$PROJECT_ROOT/.github/workflows/reusable-prepare.yml"
build="$PROJECT_ROOT/.github/workflows/reusable-build-web-backend.yml"

require_text() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || {
    printf 'Missing required workflow text in %s: %s\n' "$file" "$text" >&2
    exit 1
  }
}

require_text "$prepare" 'value: ${{ jobs.prepare.outputs.primary_sha }}'
require_text "$prepare" 'value: ${{ jobs.prepare.outputs.secondary_sha }}'
require_text "$prepare" 'publish_supported:'
require_text "$prepare" 'value: ${{ jobs.prepare.outputs.publish_authorized }}'
require_text "$prepare" '[ "$DEPLOY" = false ]'
require_text "$prepare" '[ "$UPLOAD_ARTIFACT" = false ]'
require_text "$prepare" 'This workflow cannot publish or lacks a canonical version.'
require_text "$prepare" 'Publication lacks the dispatcher-owned Action-bound confirmation.'
require_text "$prepare" 'Dispatcher-bound Action SHA is missing, invalid, or stale.'
require_text "$prepare" 'Browser Runtime source trust root is unresolved; prepare is blocked.'

for caller in one-user.yml one-amz.yml; do
  workflow="$PROJECT_ROOT/.github/workflows/$caller"
  require_text "$workflow" 'needs: prepare'
  require_text "$workflow" 'uses: ./.github/workflows/reusable-build-web-backend.yml'
  require_text "$workflow" 'backend_sha: ${{ needs.prepare.outputs.primary_sha }}'
  require_text "$workflow" 'web_sha: ${{ needs.prepare.outputs.secondary_sha }}'
  require_text "$workflow" 'rust_validation: strict'
  require_text "$workflow" 'publish_supported: true'
  require_text "$workflow" 'source_read_token: ${{ secrets.SOURCE_READ_TOKEN }}'
done

require_text "$PROJECT_ROOT/.github/workflows/one-user.yml" 'local_image_name: local/one-user-backend:${{ needs.prepare.outputs.primary_sha }}'
require_text "$PROJECT_ROOT/.github/workflows/one-amz.yml" 'local_image_name: local/one-amz-backend:${{ needs.prepare.outputs.primary_sha }}'

require_text "$PROJECT_ROOT/.github/workflows/one-amz.yml" 'name: One AMZ'
require_text "$PROJECT_ROOT/.github/workflows/one-amz.yml" 'workflow_name: one-amz'
require_text "$PROJECT_ROOT/.github/workflows/one-amz.yml" 'description: One AMZ backend repository'
require_text "$PROJECT_ROOT/make/config.mk" 'ONE_AMZ_BACKEND_REPOSITORY ?= voiceofhu/one-amz-backend-next'
require_text "$PROJECT_ROOT/make/config.mk" 'ONE_AMZ_WEB_REPOSITORY ?= voiceofhu/one-amz-web-next'
require_text "$PROJECT_ROOT/make/workflows.mk" 'dispatch-one-amz:'

require_text "$build" 'ref: ${{ inputs.backend_sha }}'
require_text "$build" 'ref: ${{ inputs.web_sha }}'
require_text "$build" 'cp -R web/dist/. backend/web-dist/'
require_text "$build" 'pnpm --dir web install --frozen-lockfile'
require_text "$build" 'pnpm --dir web format:check'
require_text "$build" 'pnpm --dir web lint'
require_text "$build" 'pnpm --dir web typecheck'
require_text "$build" 'pnpm --dir web build'
require_text "$build" '--all-targets --all-features --locked'
require_text "$build" '--all-features --locked -- -D warnings'
require_text "$build" '--release --all-features --locked'
require_text "$build" 'test -f backend/Dockerfile'
require_text "$build" 'test -f backend/web-dist/index.html'
require_text "$build" 'local_image_name tag must equal backend_sha'
require_text "$build" 'docker build --file backend/Dockerfile --tag "$LOCAL_IMAGE_NAME" backend'
require_text "$build" "docker image inspect --format '{{.Config.User}}'"
require_text "$build" 'image_principal="${image_user%%:*}"'
require_text "$build" '[ "${image_principal,,}" = root ]'
require_text "$build" '[[ "$image_principal" =~ ^0+$ ]]'
require_text "$build" "docker image inspect --format '{{.Id}}'"
require_text "$build" 'local_image: {'
require_text "$build" 'published: false'
require_text "$build" 'Local image ID:'
require_text "$build" 'Container user:'
require_text "$build" 'action/scripts/release/write-checksums.sh'
require_text "$build" 'provenance/manifest.json'
require_text "$build" 'Artifact upload: not run'
require_text "$build" 'Publish/deploy: not run'

install_line="$(grep -nF 'pnpm --dir web install --frozen-lockfile' "$build" | cut -d: -f1)"
format_line="$(grep -nF 'pnpm --dir web format:check' "$build" | cut -d: -f1)"
lint_line="$(grep -nF 'pnpm --dir web lint' "$build" | cut -d: -f1)"
typecheck_line="$(grep -nF 'pnpm --dir web typecheck' "$build" | cut -d: -f1)"
build_line="$(grep -nF 'pnpm --dir web build' "$build" | cut -d: -f1)"
if ! ((install_line < format_line && format_line < lint_line \
  && lint_line < typecheck_line && typecheck_line < build_line)); then
  printf '%s\n' 'Web verification must run after frozen install and before build.' >&2
  exit 1
fi

package_line="$(grep -nF 'cp -R web/dist/. backend/web-dist/' "$build" | cut -d: -f1)"
rust_build_line="$(grep -nF 'cargo build --release --all-features --locked' "$build" | cut -d: -f1)"
docker_build_line="$(grep -nF 'docker build --file backend/Dockerfile' "$build" | cut -d: -f1)"
if ! ((package_line < rust_build_line && rust_build_line < docker_build_line)); then
  printf '%s\n' 'Docker verification must run after Web packaging and strict Rust build.' >&2
  exit 1
fi

if grep -Eq 'inputs\.(backend_ref|web_ref)' "$build"; then
  printf '%s\n' 'Combined build workflow consumes a mutable source ref.' >&2
  exit 1
fi

if grep -Eq 'upload-artifact|docker/login-action|docker/build-push-action|docker (login|push)|ghcr\.io' "$build"; then
  printf '%s\n' 'Combined build workflow unexpectedly uploads or publishes output.' >&2
  exit 1
fi

printf '%s\n' 'Combined build workflow contract tests passed.'
