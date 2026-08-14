#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build="$PROJECT_ROOT/.github/workflows/reusable-build-rust-docker.yml"
browser="$PROJECT_ROOT/.github/workflows/one-browser-backend.yml"
egress="$PROJECT_ROOT/.github/workflows/egress.yml"
make_workflows="$PROJECT_ROOT/make/workflows.mk"

require_text() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || {
    printf 'Missing required workflow text in %s: %s\n' "$file" "$text" >&2
    exit 1
  }
}

for caller in "$browser" "$egress"; do
  require_text "$caller" 'needs: prepare'
  require_text "$caller" 'uses: ./.github/workflows/reusable-build-rust-docker.yml'
  require_text "$caller" 'source_sha: ${{ needs.prepare.outputs.primary_sha }}'
  require_text "$caller" 'rust_validation: strict'
  require_text "$caller" 'publish: ${{ inputs.publish }}'
  require_text "$caller" 'deploy: ${{ inputs.deploy }}'
done

require_text "$browser" 'local_image_name: local/one-browser-backend:${{ needs.prepare.outputs.primary_sha }}'
require_text "$browser" 'source_repository: ${{ inputs.backend_repository }}'
require_text "$egress" 'local_image_name: local/one-browser-egress:${{ needs.prepare.outputs.primary_sha }}'
require_text "$egress" 'source_repository: ${{ inputs.egress_repository }}'
require_text "$make_workflows" 'version="$${VERSION}" environment="$${ENVIRONMENT}"'
require_text "$make_workflows" 'publish="$${PUBLISH}" deploy="$${DEPLOY}"'

require_text "$build" 'ref: ${{ inputs.source_sha }}'
require_text "$build" 'local_image_name tag must equal source_sha'
require_text "$build" 'cargo fmt --all -- --check'
require_text "$build" 'cargo check --all-targets --all-features --locked'
require_text "$build" 'cargo clippy --all-targets --all-features --locked -- -D warnings'
require_text "$build" 'cargo test --all-features --locked'
require_text "$build" 'cargo build --release --all-features --locked'
require_text "$build" 'test -f source/Dockerfile'
require_text "$build" 'docker build --file source/Dockerfile --tag "$LOCAL_IMAGE_NAME" source'
require_text "$build" "docker image inspect --format '{{.Config.User}}'"
require_text "$build" 'image_principal="${image_user%%:*}"'
require_text "$build" '[ "${image_principal,,}" = root ]'
require_text "$build" '[[ "$image_principal" =~ ^0+$ ]]'
require_text "$build" "docker image inspect --format '{{.Id}}'"
require_text "$build" 'source: {'
require_text "$build" 'local_image: {'
require_text "$build" 'published: false'
require_text "$build" 'action/scripts/release/write-checksums.sh'
require_text "$build" 'provenance/manifest.json'
require_text "$build" 'Local image ID:'
require_text "$build" 'Container user:'
require_text "$build" 'Artifact upload: not run'
require_text "$build" 'Login/push/release/deploy: not run'

rust_build_line="$(grep -nF 'cargo build --release --all-features --locked' "$build" | cut -d: -f1)"
docker_build_line="$(grep -nF 'docker build --file source/Dockerfile' "$build" | cut -d: -f1)"
provenance_line="$(grep -nF 'provenance/manifest.json' "$build" | head -1 | cut -d: -f1)"
if ! ((rust_build_line < docker_build_line && docker_build_line < provenance_line)); then
  printf '%s\n' 'Rust, Docker, and provenance stages are out of order.' >&2
  exit 1
fi

if grep -Eq 'inputs\.source_ref' "$build"; then
  printf '%s\n' 'Rust/Docker workflow consumes a mutable source ref.' >&2
  exit 1
fi

if grep -Eq 'upload-artifact|docker/login-action|docker/build-push-action|docker (login|push)|ghcr\.io|gh release' "$build"; then
  printf '%s\n' 'Rust/Docker workflow unexpectedly uploads, publishes, or releases output.' >&2
  exit 1
fi

printf '%s\n' 'Rust/Docker workflow contract tests passed.'
