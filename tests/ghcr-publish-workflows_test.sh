#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
prepare="$PROJECT_ROOT/.github/workflows/reusable-prepare.yml"
combined="$PROJECT_ROOT/.github/workflows/reusable-publish-web-backend.yml"
rust="$PROJECT_ROOT/.github/workflows/reusable-publish-rust-docker.yml"
publisher="$PROJECT_ROOT/scripts/release/publish-ghcr-image.sh"
multiarch_publisher="$PROJECT_ROOT/scripts/release/publish-ghcr-multiarch.sh"
dispatcher="$PROJECT_ROOT/scripts/github/dispatch-workflow.sh"

require_text() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || {
    printf 'Missing GHCR publication contract in %s: %s\n' "$file" "$text" >&2
    exit 1
  }
}

job_block() {
  local file="$1"
  local job="$2"
  awk -v header="  $job:" '
    $0 == header { inside=1 }
    inside && $0 ~ /^  [A-Za-z0-9_-]+:$/ && $0 != header { exit }
    inside { print }
  ' "$file"
}

require_text "$prepare" 'publish_supported:'
require_text "$prepare" 'publish_authorized:'
require_text "$prepare" 'Deployment requires One User or One Node Server production publication.'
require_text "$prepare" '[ "$UPLOAD_ARTIFACT" = false ]'
require_text "$prepare" 'version must be an unprefixed three-component numeric version'
require_text "$prepare" 'expected="enable:$WORKFLOW_NAME:$EXPECTED_ACTION_SHA"'
require_text "$prepare" 'Dispatcher-bound Action SHA is missing, invalid, or stale.'
require_text "$prepare" 'one-user-backend'
require_text "$prepare" 'one-amz-backend-next'
require_text "$prepare" 'one-node-server'
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

user="$PROJECT_ROOT/.github/workflows/user.yml"
one_amz="$PROJECT_ROOT/.github/workflows/one-amz.yml"
node_server="$PROJECT_ROOT/.github/workflows/node-server.yml"
node="$PROJECT_ROOT/.github/workflows/node.yml"
node_server_deployer="$PROJECT_ROOT/scripts/deploy/deploy-node-server.sh"

require_text "$user" 'uses: ./.github/workflows/reusable-publish-web-backend.yml'
require_text "$user" 'workflow_name: one-user'
require_text "$user" 'backend_sha: ${{ needs.normalize.outputs.backend_ref }}'
require_text "$user" 'web_sha: ${{ needs.normalize.outputs.web_ref }}'
require_text "$user" 'packages: write'
require_text "$user" 'source_read_token: ${{ secrets.GH_TOKEN }}'
require_text "$user" 'package_write_token: ${{ secrets.GH_TOKEN }}'
require_text "$user" 'One User publication accepts only the fixed source repositories.'
require_text "$user" 'One User source refs must be exact commit SHAs.'
require_text "$user" 'Publication lacks the Action-bound confirmation.'

require_text "$one_amz" 'publish_supported: true'
require_text "$one_amz" 'uses: ./.github/workflows/reusable-publish-web-backend.yml'
require_text "$one_amz" 'workflow_name: one-amz'
require_text "$one_amz" 'backend_sha: ${{ needs.prepare.outputs.primary_sha }}'
require_text "$one_amz" 'web_sha: ${{ needs.prepare.outputs.secondary_sha }}'
require_text "$one_amz" 'packages: write'
require_text "$one_amz" 'source_read_token: ${{ secrets.SOURCE_READ_TOKEN }}'

require_text "$node_server" 'workflow_name: one-node-server'
require_text "$node_server" 'uses: ./.github/workflows/reusable-publish-web-backend.yml'
require_text "$node_server" 'package_write_token: ${{ secrets.GH_TOKEN }}'
require_text "$node_server" 'exec bash action/scripts/deploy/deploy-node-server.sh'
require_text "$node_server" "url: \${{ vars.DEPLOY_URL || 'https://marseo.eu.org' }}"
require_text "$node_server" "PUBLIC_URL: \${{ vars.DEPLOY_URL || 'https://marseo.eu.org' }}"
require_text "$node_server_deployer" 'PUBLIC_URL=${PUBLIC_URL:-https://marseo.eu.org}'
require_text "$node_server_deployer" '"$public_url/api/healthz"'
require_text "$node_server_deployer" '"$public_url/"'
require_text "$node_server_deployer" 'One Node Server public endpoint is ready:'

for direct_workflow in "$user" "$node_server" "$node"; do
  if grep -Eq 'protocol_contract|Validate immutable deployment image|needs\.prepare|publish_authorized' \
    "$direct_workflow"; then
    printf 'Direct build workflow retains a validation gate: %s\n' "$direct_workflow" >&2
    exit 1
  fi
done

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
require_text "$combined" 'name: Build Web from the fresh checkout'
require_text "$combined" 'cp -R "web/$WEB_OUTPUT_DIR/." backend/web-dist/'
require_text "$combined" 'cargo fmt --all -- --check'
require_text "$combined" 'cargo clippy --all-targets --all-features --locked -- -D warnings'
require_text "$combined" 'cargo test --all-features --locked'
require_text "$combined" 'org.opencontainers.image.version=${{ inputs.version }}'
require_text "$combined" 'one.action.repository=${{ github.repository }}'
require_text "$combined" 'ghcr.io/voiceofhu/one-user'
require_text "$combined" 'publish_tag="$VERSION"'
require_text "$combined" 'ghcr.io/voiceofhu/one-amz-backend-next'
require_text "$combined" 'ghcr.io/voiceofhu/node-server'
require_text "$combined" 'expected_backend_repository=voiceofhu/one-user-backend'
require_text "$combined" 'expected_web_repository=voiceofhu/one-user-web'
require_text "$combined" 'expected_backend_repository=voiceofhu/one-amz-backend-next'
require_text "$combined" 'expected_web_repository=voiceofhu/one-amz-web-next'
require_text "$combined" 'expected_backend_repository=voiceofhu/one-node-server'
require_text "$combined" 'expected_web_repository=voiceofhu/one-node-web'
require_text "$combined" 'publication sources do not match the fixed product repositories'
require_text "$combined" 'ACTION_REPOSITORY" != voiceofhu/one-action'
require_text "$combined" 'group: ghcr-${{ inputs.workflow_name }}-publish'
require_text "$combined" 'source_read_token:'
require_text "$combined" 'package_write_token:'
require_text "$combined" 'token: ${{ secrets.source_read_token }}'
require_text "$combined" 'password: ${{ secrets.package_write_token || github.token }}'
require_text "$combined" 'Backend checkout HEAD does not match backend_sha.'
require_text "$combined" 'Web checkout HEAD does not match web_sha.'
require_text "$combined" 'web_package=one-user-web'
require_text "$combined" 'web_package=one-amz-web'
require_text "$combined" 'web_package=one-node-web-vite'
require_text "$combined" 'backend_dockerfile=deploy/docker/Dockerfile'
require_text "$combined" 'backend_dockerfile=Dockerfile'
require_text "$combined" 'backend_dockerfile: ${{ steps.config.outputs.backend_dockerfile }}'
require_text "$combined" 'echo "backend_dockerfile=$backend_dockerfile"'
require_text "$combined" 'BACKEND_DOCKERFILE: ${{ needs.plan.outputs.backend_dockerfile }}'
require_text "$combined" 'web_version="$(jq -er '\''.version | select(type == "string")'\'' web/package.json)"'
require_text "$combined" 'Requested version does not match the Web package version.'
require_text "$combined" 'Requested version does not match the backend Cargo package version.'
require_text "$combined" 'pnpm --dir web exec vite build --mode development'
require_text "$combined" 'pnpm --dir web build:stage'
require_text "$combined" 'Web dist may contain only regular files and directories.'
require_text "$combined" 'test -f "backend/$BACKEND_DOCKERFILE" && test ! -L "backend/$BACKEND_DOCKERFILE"'
require_text "$combined" 'platform: linux/amd64'
require_text "$combined" 'runner: ubuntu-latest'
require_text "$combined" 'suffix: amd64'
require_text "$combined" 'platform: linux/arm64'
require_text "$combined" 'runner: ubuntu-24.04-arm'
require_text "$combined" 'suffix: arm64'
require_text "$combined" 'docker/build-push-action@v6'
require_text "$combined" 'platforms: ${{ matrix.platform }}'
require_text "$combined" 'context: backend'
require_text "$combined" 'file: backend/${{ needs.plan.outputs.backend_dockerfile }}'
require_text "$combined" 'tags: ${{ needs.plan.outputs.registry_image }}:${{ needs.plan.outputs.publish_tag }}-${{ matrix.suffix }}'
require_text "$combined" 'cache-from: type=registry,ref=${{ needs.plan.outputs.registry_image }}:buildcache-${{ matrix.suffix }}'
require_text "$combined" 'cache-to: type=registry,ref=${{ needs.plan.outputs.registry_image }}:buildcache-${{ matrix.suffix }},mode=max,image-manifest=true,oci-mediatypes=true'
require_text "$combined" 'provenance: false'
require_text "$combined" 'sbom: false'
require_text "$combined" "docker buildx imagetools inspect \"\$IMAGE_REF\" --format '{{json .Image}}'"
require_text "$combined" 'Final image Config.User must be non-empty and non-root.'
require_text "$combined" 'name: Plan immutable publication'
require_text "$combined" 'name: Verify backend source'
require_text "$combined" 'name: Publish multi-platform OCI index'
require_text "$combined" "if: inputs.workflow_name != 'one-node-server' && inputs.workflow_name != 'one-user'"
require_text "$combined" "if: inputs.workflow_name == 'one-node-server' || inputs.workflow_name == 'one-user'"
require_text "$combined" 'name: Publish OCI index'
require_text "$combined" 'id: publish_fast'
require_text "$combined" 'image_ref=%s@%s'
require_text "$combined" 'Central multi-platform publisher changed after exact Action checkout.'
require_text "$combined" 'exec bash action/scripts/release/publish-ghcr-multiarch.sh'
require_text "$combined" 'value: ${{ jobs.manifest.outputs.digest }}'
require_text "$combined" 'value: ${{ jobs.manifest.outputs.image_ref }}'

if grep -Eq 'actions/(upload|download)-artifact|artifact_name' "$combined"; then
  printf '%s\n' 'Combined publisher must build Web from a fresh checkout in each architecture job.' >&2
  exit 1
fi

if grep -Fq 'pnpm --dir web typecheck' "$combined"; then
  printf '%s\n' 'Combined publisher duplicates type checking outside the environment build.' >&2
  exit 1
fi
if grep -Fq 'cargo check --all-targets --all-features --locked' "$combined"; then
  printf '%s\n' 'Combined publisher duplicates cargo check before clippy.' >&2
  exit 1
fi

verify_backend_block="$(job_block "$combined" verify_backend)"
build_block="$(job_block "$combined" build)"
manifest_block="$(job_block "$combined" manifest)"

grep -Fq 'needs: plan' <<<"$verify_backend_block" || {
  printf '%s\n' 'Backend verification must depend on the immutable publication plan.' >&2
  exit 1
}
grep -Fq 'needs: plan' <<<"$build_block" || {
  printf '%s\n' 'Architecture builds must depend on the immutable publication plan.' >&2
  exit 1
}
if grep -Fq -- '- verify_backend' <<<"$build_block"; then
  printf '%s\n' 'Architecture builds must run in parallel with backend verification.' >&2
  exit 1
fi
for dependency in plan verify_backend build; do
  grep -Fq -- "- $dependency" <<<"$manifest_block" || {
    printf 'OCI manifest quality gate must depend on %s.\n' "$dependency" >&2
    exit 1
  }
done

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
  if grep -Eq "ghcr\\.io/[^[:space:]\"']+:(latest|dev|stage|prod)([[:space:]\"']|$)|:[[:space:]]+(latest|dev|stage|prod)([[:space:]]|$)" \
    "$reusable"; then
    printf 'Publisher contains a mutable tag: %s\n' "$reusable" >&2
    exit 1
  fi
done

require_text "$combined" 'GITHUB_TOKEN: ${{ secrets.package_write_token || github.token }}'
require_text "$combined" 'PUBLISHED_IMAGE_PATH: publication/published-image.json'
if [ "$(grep -Fc 'GITHUB_TOKEN: ${{ secrets.package_write_token || github.token }}' "$combined")" -ne 1 ]; then
  printf '%s\n' 'Combined publisher token must be exposed only to the final manifest step.' >&2
  exit 1
fi

require_text "$rust" 'GITHUB_TOKEN: ${{ github.token }}'
require_text "$rust" 'PUBLISHED_IMAGE_PATH: publication/published-image.json'
require_text "$rust" 'exec bash action/scripts/release/publish-ghcr-image.sh'
if grep -Eq 'upload-artifact|actions/upload-artifact' "$rust"; then
  printf '%s\n' 'Single-platform Rust publisher unexpectedly uploads an artifact.' >&2
  exit 1
fi
token_line="$(grep -nF 'GITHUB_TOKEN: ${{ github.token }}' "$rust" | cut -d: -f1)"
push_line="$(grep -nF 'Login briefly, push unique tag' "$rust" | cut -d: -f1)"
if ! ((push_line < token_line)); then
  printf '%s\n' 'Registry token is not scoped to the final push step in the Rust publisher.' >&2
  exit 1
fi

require_text "$publisher" 'ghcr.io/voiceofhu/one-user'
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

require_text "$multiarch_publisher" 'GHCR multi-platform publication blocked:'
require_text "$multiarch_publisher" 'one-user:ghcr.io/voiceofhu/one-user'
require_text "$multiarch_publisher" 'one-amz:ghcr.io/voiceofhu/one-amz-backend-next'
require_text "$multiarch_publisher" 'PUBLISH_TAG does not match the publication version policy'
require_text "$multiarch_publisher" 'multi-platform publication tag already exists and will not be overwritten'
require_text "$multiarch_publisher" 'amd64 image tag returned HTTP'
require_text "$multiarch_publisher" 'arm64 image tag returned HTTP'
require_text "$multiarch_publisher" 'docker buildx imagetools create'
require_text "$multiarch_publisher" '"$PUBLISH_TAG-amd64"'
require_text "$multiarch_publisher" '"$PUBLISH_TAG-arm64"'
require_text "$multiarch_publisher" '"$PUBLISH_IMAGE@$amd64_digest"'
require_text "$multiarch_publisher" '"$PUBLISH_IMAGE@$arm64_digest"'
require_text "$multiarch_publisher" 'published_status="$(registry_manifest_status "$PUBLISH_TAG")"'
require_text "$multiarch_publisher" 'digest="$(registry_manifest_digest)"'
require_text "$multiarch_publisher" 'image_ref="$PUBLISH_IMAGE:$PUBLISH_TAG@$digest"'
require_text "$multiarch_publisher" 'docker buildx imagetools inspect "$image_ref" --raw'
require_text "$multiarch_publisher" \
  'docker buildx imagetools inspect "$image_ref" --format '\''{{json .Manifest}}'\'''
require_text "$multiarch_publisher" '.mediaType == "application/vnd.oci.image.index.v1+json"'
require_text "$multiarch_publisher" 'published OCI index must contain exactly linux/amd64 and linux/arm64'
require_text "$multiarch_publisher" 'published OCI index descriptor does not match the immutable registry digest'
require_text "$multiarch_publisher" 'published multi-platform tag does not resolve to the OCI index digest'
require_text "$multiarch_publisher" 'image_ref=$image_ref'
require_text "$multiarch_publisher" '.image.reference == (.image.name + ":" + .image.tag + "@" + .image.digest)'
require_text "$multiarch_publisher" 'platforms: ['

if grep -Fq 'imagetools inspect "$final_ref"' "$multiarch_publisher"; then
  printf '%s\n' 'Multi-platform publisher validates the final index through a mutable tag.' >&2
  exit 1
fi

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
    expected_source_secret_count=1
  else
    source_secret='source_read_token: ${{ secrets.SOURCE_READ_TOKEN }}'
    expected_source_secret_count=3
  fi
  source_secret_count="$(grep -Fc "$source_secret" "$caller" || true)"
  if [ "$source_secret_count" -ne "$expected_source_secret_count" ]; then
    printf 'Caller does not pass the explicit source credential to its exact jobs: %s\n' "$caller" >&2
    exit 1
  fi
done

printf '%s\n' 'GHCR publication workflow contract tests passed.'
