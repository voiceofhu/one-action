#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
node_server="$PROJECT_ROOT/.github/workflows/node-server.yml"
publisher="$PROJECT_ROOT/.github/workflows/reusable-publish-web-backend.yml"
release="$PROJECT_ROOT/scripts/release/deploy-node-server-release.sh"
deployer="$PROJECT_ROOT/scripts/deploy/deploy-node-server.sh"

require_text() {
  local file=$1 text=$2
  grep -Fq -- "$text" "$file" || {
    printf 'Missing Node Server contract in %s: %s\n' "${file##*/}" "$text" >&2
    exit 1
  }
}

reject_text() {
  local file=$1 text=$2
  if grep -Fiq -- "$text" "$file"; then
    printf 'Forbidden Node Server contract in %s: %s\n' "${file##*/}" "$text" >&2
    exit 1
  fi
}

for file in "$node_server" "$publisher" "$release" "$deployer"; do
  [[ -f "$file" ]] || {
    printf 'Missing Node Server release file: %s\n' "$file" >&2
    exit 1
  }
done

ruby -ryaml -e '
  workflow = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
  trigger = workflow.fetch("on")
  abort("Node Server workflow trigger must contain only push") unless
    trigger.keys == ["push"]
  abort("unexpected Node Server control tag") unless
    trigger.fetch("push").fetch("tags") == ["node-server-v*"]
  jobs = workflow.fetch("jobs")
  abort("unexpected Node Server jobs") unless
    jobs.keys.sort == %w[deploy prepare publish]
  abort("Node Server prepare timeout changed") unless
    jobs.fetch("prepare").fetch("timeout-minutes") <= 2
  deploy = jobs.fetch("deploy")
  abort("Node Server deploy dependencies changed") unless
    deploy.fetch("needs") == %w[prepare publish]
  abort("Node Server deploy timeout changed") unless
    deploy.fetch("timeout-minutes") <= 20
  abort("Node Server deployment environment changed") unless
    deploy.fetch("environment").fetch("name") == "one-node-prod"
  abort("Node Server deployment concurrency changed") unless
    deploy.fetch("concurrency") == {
      "group" => "one-node-server-prod-deploy",
      "cancel-in-progress" => false
    }
' "$node_server"

ruby -ryaml -e '
  workflow = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
  jobs = workflow.fetch("jobs")
  abort("unexpected shared publisher jobs") unless
    jobs.keys.sort == %w[build manifest]
  abort("shared publisher build timeout changed") unless
    jobs.fetch("build").fetch("timeout-minutes") <= 20
  abort("shared publisher manifest timeout changed") unless
    jobs.fetch("manifest").fetch("timeout-minutes") <= 3
  matrix = jobs.fetch("build").fetch("strategy").fetch("matrix").fetch("include")
  expected = [
    {"arch" => "amd64", "platform" => "linux/amd64", "runner" => "ubuntu-24.04"},
    {"arch" => "arm64", "platform" => "linux/arm64", "runner" => "ubuntu-24.04-arm"}
  ]
  abort("shared publisher architecture matrix changed") unless matrix == expected
' "$publisher"

for text in \
  'group: one-node-server-publish-${{ github.ref_name }}' \
  'workflow_name: one-node-server' \
  'format="$(manifest_field format)"' \
  'backend_sha="$(manifest_field backend_sha)"' \
  'web_sha="$(manifest_field web_sha)"' \
  'gh api "repos/voiceofhu/one-node-server/commits/$backend_sha"' \
  'gh api "repos/voiceofhu/one-node-web/commits/$web_sha"' \
  'uses: ./.github/workflows/reusable-publish-web-backend.yml' \
  'name: Deploy One Node Server image' \
  'name: one-node-prod' \
  'group: one-node-server-prod-deploy' \
  'DOCKER_IMAGE: ${{ needs.publish.outputs.image_ref }}' \
  'COMPOSE_FILE: server/deploy/docker-compose.yml' \
  'run: exec bash action/scripts/deploy/deploy-node-server.sh'; do
  require_text "$node_server" "$text"
done
reject_text "$node_server" 'source_tag='
reject_text "$node_server" 'workflow_dispatch:'

for text in \
  'ref: ${{ inputs.backend_sha }}' \
  'ref: ${{ inputs.web_sha }}' \
  'pnpm --dir web install --frozen-lockfile' \
  'pnpm --dir web build' \
  'mkdir backend/web-dist' \
  'uses: docker/build-push-action@v6' \
  'platforms: ${{ matrix.platform }}' \
  'push: true' \
  'org.opencontainers.image.revision=${{ inputs.backend_sha }}' \
  'one.web.revision=${{ inputs.web_sha }}' \
  'docker buildx imagetools create' \
  'index:one.action.revision=$ACTION_SHA' \
  'index:org.opencontainers.image.revision=$BACKEND_SHA' \
  'index:one.web.revision=$WEB_SHA'; do
  require_text "$publisher" "$text"
done

for text in \
  'make --no-print-directory -C "$PROJECT_ROOT" validate-node-server' \
  'make --no-print-directory -C "$ONE_NODE_WEB_DIR" install check build' \
  'make --no-print-directory -C "$ONE_NODE_SERVER_DIR" test' \
  'go vet ./...' \
  'format=one-node-server-release-v1' \
  'tag -a "$control_tag" "$action_head" -m "$control_manifest"' \
  'Triggered One Node Server image publication and server deployment'; do
  require_text "$release" "$text"
done
reject_text "$release" 'git -C "$ONE_NODE_SERVER_DIR" tag'
reject_text "$release" 'git -C "$ONE_NODE_WEB_DIR" tag'

for text in \
  '^ghcr\.io/voiceofhu/node-server:' \
  'docker-compose.yml.next' \
  '"http://127.0.0.1:$published_port/api/healthz"' \
  '"$public_url/api/healthz"' \
  'attempting to restore the previous container'; do
  require_text "$deployer" "$text"
done

printf '%s\n' 'One Node Server publication and deployment contracts passed.'
