#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
prepare="$PROJECT_ROOT/.github/workflows/reusable-prepare.yml"
combined="$PROJECT_ROOT/.github/workflows/reusable-publish-web-backend.yml"
rust="$PROJECT_ROOT/.github/workflows/reusable-publish-rust-docker.yml"
publisher="$PROJECT_ROOT/scripts/release/publish-ghcr-image.sh"
dispatcher="$PROJECT_ROOT/scripts/github/dispatch-workflow.sh"

require_text() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || {
    printf 'Missing GHCR publication contract in %s: %s\n' "$file" "$text" >&2
    exit 1
  }
}

require_text "$prepare" 'publish_supported:'
require_text "$prepare" 'publish_authorized:'
require_text "$prepare" 'Deployment requires One User production publication.'
require_text "$prepare" '[ "$UPLOAD_ARTIFACT" = false ]'
require_text "$prepare" 'version must be an unprefixed three-component numeric version'
require_text "$prepare" 'expected="enable:$WORKFLOW_NAME:$EXPECTED_ACTION_SHA"'
require_text "$prepare" 'Dispatcher-bound Action SHA is missing, invalid, or stale.'
require_text "$prepare" 'one-user-backend-next'
require_text "$prepare" 'one-amz-backend-next'
require_text "$prepare" 'one-browser-backend-next'
require_text "$prepare" 'one-browser-egress-next'
require_text "$prepare" 'Public Egress releases require environment=prod.'
require_text "$prepare" 'labels, repositories, or publication policy differ from the fixed contract.'
require_text "$prepare" 'source_read_token:'
require_text "$prepare" 'secrets.source_read_token || github.token'
prepare_source_secret_count="$(
  grep -Fc 'secrets.source_read_token || github.token' "$prepare" || true
)"
if [ "$prepare_source_secret_count" -ne 3 ]; then
  printf '%s\n' 'Prepare ref resolution and both source checkouts must use the explicit credential.' >&2
  exit 1
fi

for workflow_name in one-user one-amz; do
  if [ "$workflow_name" = one-user ]; then
    caller="$PROJECT_ROOT/.github/workflows/user.yml"
  else
    caller="$PROJECT_ROOT/.github/workflows/$workflow_name.yml"
  fi
  require_text "$caller" 'publish_supported: true'
  require_text "$caller" 'uses: ./.github/workflows/reusable-publish-web-backend.yml'
  require_text "$caller" "workflow_name: $workflow_name"
  require_text "$caller" 'backend_sha: ${{ needs.prepare.outputs.primary_sha }}'
  require_text "$caller" 'web_sha: ${{ needs.prepare.outputs.secondary_sha }}'
  require_text "$caller" 'packages: write'
done
require_text "$PROJECT_ROOT/.github/workflows/user.yml" 'source_read_token: ${{ secrets.GH_TOKEN }}'
require_text "$PROJECT_ROOT/.github/workflows/one-amz.yml" 'source_read_token: ${{ secrets.SOURCE_READ_TOKEN }}'

browser="$PROJECT_ROOT/.github/workflows/one-browser-backend.yml"
require_text "$browser" 'publish_supported: true'
require_text "$browser" 'uses: ./.github/workflows/reusable-publish-rust-docker.yml'
require_text "$browser" 'source_sha: ${{ needs.prepare.outputs.primary_sha }}'
require_text "$browser" 'packages: write'
require_text "$browser" 'source_read_token: ${{ secrets.SOURCE_READ_TOKEN }}'

for workflow_name in app app-debug browser-runtime; do
  require_text "$PROJECT_ROOT/.github/workflows/$workflow_name.yml" 'publish_supported: false'
done

require_text "$PROJECT_ROOT/.github/workflows/egress.yml" 'publish_supported: true'
require_text "$PROJECT_ROOT/.github/workflows/egress.yml" 'uses: ./.github/workflows/reusable-publish-egress.yml'

require_text "$combined" 'ref: ${{ inputs.backend_sha }}'
require_text "$combined" 'ref: ${{ inputs.web_sha }}'
require_text "$combined" 'persist-credentials: false'
require_text "$combined" 'pnpm --dir web install --frozen-lockfile'
require_text "$combined" 'pnpm --dir web format:check'
require_text "$combined" 'pnpm --dir web lint'
require_text "$combined" 'pnpm --dir web typecheck'
require_text "$combined" 'cp -R web/dist/. backend/web-dist/'
require_text "$combined" 'cargo clippy --all-targets --all-features --locked -- -D warnings'
require_text "$combined" '--label "org.opencontainers.image.version=$VERSION"'
require_text "$combined" '--label "one.action.repository=$ACTION_REPOSITORY"'
require_text "$combined" 'ghcr.io/voiceofhu/one-user-backend-next'
require_text "$combined" 'ghcr.io/voiceofhu/one-amz-backend-next'
require_text "$combined" 'expected_backend_repository=voiceofhu/one-user-backend-next'
require_text "$combined" 'expected_web_repository=voiceofhu/one-user-web-next'
require_text "$combined" 'expected_backend_repository=voiceofhu/one-amz-backend-next'
require_text "$combined" 'expected_web_repository=voiceofhu/one-amz-web-next'
require_text "$combined" 'publication sources do not match the fixed product repositories'
require_text "$combined" 'ACTION_REPOSITORY" != voiceofhu/one-action'
require_text "$combined" 'group: ghcr-${{ inputs.workflow_name }}-${{ inputs.backend_sha }}-${{ inputs.web_sha }}-${{ inputs.version }}'
require_text "$combined" 'source_read_token:'
require_text "$combined" 'token: ${{ secrets.source_read_token }}'
require_text "$combined" 'Backend checkout HEAD does not match backend_sha.'
require_text "$combined" 'Web checkout HEAD does not match web_sha.'
require_text "$combined" 'web_package=one-user-web'
require_text "$combined" 'web_package=one-amz-web'
require_text "$combined" 'web_version="$(jq -er '\''.version | select(type == "string")'\'' web/package.json)"'
require_text "$combined" 'Requested version does not match the Web package version.'
require_text "$combined" 'Requested version does not match the backend Cargo package version.'
require_text "$combined" 'pnpm --dir web exec vite build --mode development'
require_text "$combined" 'pnpm --dir web build:stage'
require_text "$combined" 'Web dist may contain only regular files and directories.'
require_text "$combined" 'GIT_NO_REPLACE_OBJECTS=1 git -C backend archive --format=tar "$BACKEND_SHA"'
require_text "$combined" 'test -f docker-context/Dockerfile && test ! -L docker-context/Dockerfile'
require_text "$combined" 'Central publisher script changed after exact Action checkout.'

require_text "$rust" 'ref: ${{ inputs.source_sha }}'
require_text "$rust" 'persist-credentials: false'
require_text "$rust" 'cargo test --all-features --locked'
require_text "$rust" 'docker build'
require_text "$rust" '--label "org.opencontainers.image.version=$VERSION"'
require_text "$rust" '--label "one.action.repository=$ACTION_REPOSITORY"'
require_text "$rust" 'ghcr.io/voiceofhu/one-browser-backend-next'
require_text "$rust" 'SOURCE_REPOSITORY" != voiceofhu/one-browser-backend-next'
require_text "$rust" 'ACTION_REPOSITORY" != voiceofhu/one-action'
require_text "$rust" 'group: ghcr-one-browser-backend-${{ inputs.source_sha }}-${{ inputs.version }}'
require_text "$rust" 'source_read_token:'
require_text "$rust" 'token: ${{ secrets.source_read_token }}'
require_text "$rust" 'Backend checkout HEAD does not match source_sha.'
require_text "$rust" 'package_name=one-browser-backend'
require_text "$rust" 'Requested version does not match the backend Cargo package version.'
require_text "$rust" 'GIT_NO_REPLACE_OBJECTS=1 git -C source archive --format=tar "$SOURCE_SHA"'
require_text "$rust" 'test -f docker-context/Dockerfile && test ! -L docker-context/Dockerfile'
require_text "$rust" 'Central publisher script changed after exact Action checkout.'

for reusable in "$combined" "$rust"; do
  require_text "$reusable" 'contents: read'
  require_text "$reusable" 'packages: write'
  require_text "$reusable" 'environment: ghcr-publish'
  require_text "$reusable" 'Final image Config.User must be non-empty and non-root.'
  require_text "$reusable" 'GITHUB_TOKEN: ${{ github.token }}'
  require_text "$reusable" 'PUBLISHED_IMAGE_PATH: publication/published-image.json'
  require_text "$reusable" 'exec bash action/scripts/release/publish-ghcr-image.sh'
  if grep -Eq "upload-artifact|actions/upload-artifact|ghcr\\.io/[^[:space:]\"']+:(latest|dev|stage|prod)([[:space:]\"']|$)|:[[:space:]]+(latest|dev|stage|prod)([[:space:]]|$)" \
    "$reusable"; then
    printf 'Publisher contains an upload or mutable tag: %s\n' "$reusable" >&2
    exit 1
  fi
  token_line="$(grep -nF 'GITHUB_TOKEN: ${{ github.token }}' "$reusable" | cut -d: -f1)"
  push_line="$(grep -nF 'Login briefly, push unique tag' "$reusable" | cut -d: -f1)"
  if ! ((push_line < token_line)); then
    printf 'Registry token is not scoped to the final push step: %s\n' "$reusable" >&2
    exit 1
  fi
done

require_text "$publisher" 'ghcr.io/voiceofhu/one-user-backend-next'
require_text "$publisher" 'ghcr.io/voiceofhu/one-amz-backend-next'
require_text "$publisher" 'ghcr.io/voiceofhu/one-browser-backend-next'
require_text "$publisher" 'combined sources do not match the fixed product repositories'
require_text "$publisher" 'backend source does not match the fixed product repository'
require_text "$publisher" 'ACTION_REPOSITORY must be the fixed central Action repository'
require_text "$publisher" 'RUN_URL is not bound to the fixed Action repository and run ID'
require_text "$publisher" 'printf '\''%s'\'' "$GITHUB_TOKEN" | docker login ghcr.io'
require_text "$publisher" 'unset GITHUB_TOKEN'
require_text "$publisher" 'unique run tag already exists and will not be overwritten'
require_text "$publisher" 'GHCR manifest HEAD failed before a trustworthy status was returned'
require_text "$publisher" 'could not prove the unique run tag is absent; registry returned HTTP'
require_text "$publisher" '${PUBLISH_TAG}: digest: (sha256:[0-9a-f]{64}) size:'
require_text "$publisher" 'registry push did not return exactly one canonical digest line'
require_text "$publisher" 'docker buildx imagetools inspect "$PUBLISH_IMAGE@$digest" --raw'
require_text "$publisher" 'published run tag does not resolve to the registry digest returned by push'
require_text "$publisher" 'local combined image labels are not bound to the exact backend and Web sources'
require_text "$publisher" 'local backend image labels are not bound to the exact source'
require_text "$publisher" 'published: true'
require_text "$publisher" 'action_repository: $action_repository'
require_text "$publisher" '.action_repository == "voiceofhu/one-action"'
require_text "$publisher" 'Action: \`$ACTION_REPOSITORY@$ACTION_SHA\`'
require_text "$publisher" 'Deploy: not run'
require_text "$publisher" 'final image Config.User must be non-empty and non-root'
require_text "$publisher" 'VERSION must not exceed 32 characters'

require_text "$dispatcher" 'confirmation is dispatcher-owned and must not be supplied by a caller'
require_text "$dispatcher" 'enable:$workflow_base:$action_sha'
require_text "$dispatcher" 'mutation_confirmation="mutate:$workflow:$action_sha"'

for caller in \
  "$PROJECT_ROOT/.github/workflows/user.yml" \
  "$PROJECT_ROOT/.github/workflows/one-amz.yml" \
  "$PROJECT_ROOT/.github/workflows/one-browser-backend.yml"; do
  if grep -Fq 'secrets: inherit' "$caller"; then
    printf 'Publication caller inherits unrelated repository secrets: %s\n' "$caller" >&2
    exit 1
  fi
  if [ "$(basename "$caller")" = user.yml ]; then
    source_secret='source_read_token: ${{ secrets.GH_TOKEN }}'
  else
    source_secret='source_read_token: ${{ secrets.SOURCE_READ_TOKEN }}'
  fi
  source_secret_count="$(grep -Fc "$source_secret" "$caller" || true)"
  if [ "$source_secret_count" -ne 3 ]; then
    printf 'Prepare/build/publish must each receive only the explicit source credential: %s\n' \
      "$caller" >&2
    exit 1
  fi
done

printf '%s\n' 'GHCR publication workflow contract tests passed.'
