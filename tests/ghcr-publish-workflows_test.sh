#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
user="$PROJECT_ROOT/.github/workflows/user.yml"
node_server="$PROJECT_ROOT/.github/workflows/node-server.yml"
publisher="$PROJECT_ROOT/.github/workflows/reusable-publish-web-backend.yml"
user_release="$PROJECT_ROOT/scripts/release/deploy-user-release.sh"
node_server_release="$PROJECT_ROOT/scripts/release/deploy-node-server-release.sh"
node_server_deployer="$PROJECT_ROOT/scripts/deploy/deploy-node-server.sh"

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

assert_tag_only() {
  local file=$1 tag=$2
  ruby -ryaml -e '
    workflow = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
    trigger = workflow.fetch("on")
    expected_tag = ARGV.fetch(1)
    abort("workflow trigger must contain only push") unless trigger.keys == ["push"]
    push = trigger.fetch("push")
    abort("push trigger must contain only tags") unless push.keys == ["tags"]
    abort("unexpected control tag trigger") unless push.fetch("tags") == [expected_tag]
  ' "$file" "$tag"
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

for file in "$user" "$node_server" "$publisher" "$user_release" "$node_server_release" "$node_server_deployer"; do
  [[ -f "$file" ]] || {
    printf 'Required publication contract file is missing: %s\n' "$file" >&2
    exit 1
  }
done

assert_tag_only "$user" 'user-v*'
assert_tag_only "$node_server" 'node-server-v*'
assert_jobs "$user" 'prepare,publish'
assert_jobs "$node_server" 'deploy,prepare,publish'
assert_jobs "$publisher" 'build,manifest'
ruby -ryaml -e '
  workflow = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
  deploy = workflow.fetch("jobs").fetch("deploy")
  abort("Node Server deploy must wait for prepare and publish") unless
    deploy.fetch("needs") == ["prepare", "publish"]
  abort("Node Server deploy permissions changed") unless
    deploy.fetch("permissions") == {"contents" => "read", "packages" => "read"}
  abort("Node Server deploy environment changed") unless
    deploy.fetch("environment").fetch("name") == "one-node-prod"
  abort("Node Server deploy concurrency changed") unless
    deploy.fetch("concurrency") == {
      "group" => "one-node-server-prod-deploy", "cancel-in-progress" => false
    }
' "$node_server"
assert_timeout_at_most "$user" prepare 2
assert_timeout_at_most "$node_server" prepare 2
assert_timeout_at_most "$node_server" deploy 20
assert_timeout_at_most "$publisher" build 20
assert_timeout_at_most "$publisher" manifest 3
assert_native_matrix "$publisher"

require_text "$user" 'group: one-user-publish-${{ github.ref_name }}'
require_text "$user" 'workflow_name: one-user'
require_text "$user" 'gh api "repos/voiceofhu/one-user-backend/commits/$source_tag"'
require_text "$user" 'gh api "repos/voiceofhu/one-user-web/commits/$source_tag"'
require_text "$user" 'backend_sha: ${{ needs.prepare.outputs.backend_sha }}'
require_text "$user" 'web_sha: ${{ needs.prepare.outputs.web_sha }}'

require_text "$node_server" 'group: one-node-server-publish-${{ github.ref_name }}'
require_text "$node_server" 'workflow_name: one-node-server'
require_text "$node_server" 'gh api "repos/$ACTION_REPOSITORY/git/ref/tags/$TAG_NAME"'
require_text "$node_server" 'gh api "repos/$ACTION_REPOSITORY/git/tags/$tag_object_sha"'
require_text "$node_server" 'format="$(manifest_field format)"'
require_text "$node_server" 'backend_sha="$(manifest_field backend_sha)"'
require_text "$node_server" 'web_sha="$(manifest_field web_sha)"'
require_text "$node_server" 'gh api "repos/voiceofhu/one-node-server/commits/$backend_sha"'
require_text "$node_server" 'gh api "repos/voiceofhu/one-node-web/commits/$web_sha"'
reject_text "$node_server" 'source_tag='
require_text "$node_server" 'backend_sha: ${{ needs.prepare.outputs.backend_sha }}'
require_text "$node_server" 'web_sha: ${{ needs.prepare.outputs.web_sha }}'
require_text "$node_server" 'name: Deploy One Node Server image'
require_text "$node_server" 'name: one-node-prod'
require_text "$node_server" 'group: one-node-server-prod-deploy'
require_text "$node_server" 'ref: ${{ github.sha }}'
require_text "$node_server" 'ref: ${{ needs.prepare.outputs.backend_sha }}'
require_text "$node_server" 'SSH_ALIAS: one-node-deploy'
require_text "$node_server" 'DEPLOY_HOST: ${{ secrets.DEPLOY_HOST }}'
require_text "$node_server" "DEPLOY_PORT: \${{ secrets.DEPLOY_PORT || '22' }}"
require_text "$node_server" 'DEPLOY_USER: ${{ secrets.DEPLOY_USER }}'
require_text "$node_server" 'DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}'
require_text "$node_server" 'DEPLOY_KNOWN_HOSTS: ${{ secrets.DEPLOY_KNOWN_HOSTS }}'
require_text "$node_server" "REMOTE_DIR: \${{ vars.DEPLOY_REMOTE_DIR || '/opt/one-node' }}"
require_text "$node_server" 'DOCKER_IMAGE: ${{ needs.publish.outputs.image_ref }}'
require_text "$node_server" 'COMPOSE_FILE: server/deploy/docker-compose.yml'
require_text "$node_server" "PUBLIC_URL: \${{ vars.DEPLOY_URL || 'https://marseo.eu.org' }}"
require_text "$node_server" 'run: exec bash action/scripts/deploy/configure-ssh.sh'
require_text "$node_server" 'run: exec bash action/scripts/deploy/registry-auth.sh'
require_text "$node_server" 'run: exec bash action/scripts/deploy/deploy-node-server.sh'
require_text "$node_server" "if: \${{ always() && steps.registry_login.outcome == 'success' }}"

for caller in "$user" "$node_server"; do
  require_text "$caller" 'timeout-minutes: 2'
  require_text "$caller" '&& "$ACTION_SHA" =~ ^[0-9a-f]{40}$'
  require_text "$caller" 'backend_pid=$!'
  require_text "$caller" 'web_pid=$!'
  require_text "$caller" 'wait "$backend_pid"'
  require_text "$caller" 'wait "$web_pid"'
  require_text "$caller" "created_at=\"\$(jq -er '.commit.committer.date' \"\$web_commit_file\")\""
  require_text "$caller" 'uses: ./.github/workflows/reusable-publish-web-backend.yml'
  require_text "$caller" 'contents: read'
  require_text "$caller" 'packages: write'
  require_text "$caller" 'source_read_token: ${{ secrets.GH_TOKEN }}'
  require_text "$caller" 'package_write_token: ${{ secrets.GH_TOKEN }}'
done
require_text "$user" '[[ "$backend_sha" =~ ^[0-9a-f]{40}$ && "$web_sha" =~ ^[0-9a-f]{40}$ ]]'
require_text "$node_server" '&& "$backend_sha" =~ ^[0-9a-f]{40}$'
require_text "$node_server" '&& "$web_sha" =~ ^[0-9a-f]{40}$'

require_text "$publisher" "repository: \${{ inputs.workflow_name == 'one-user' && 'voiceofhu/one-user-backend' || 'voiceofhu/one-node-server' }}"
require_text "$publisher" "repository: \${{ inputs.workflow_name == 'one-user' && 'voiceofhu/one-user-web' || 'voiceofhu/one-node-web' }}"
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
require_text "$publisher" 'uses: docker/build-push-action@v6'
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

for workflow in "$user" "$publisher"; do
  reject_text "$workflow" '  deploy:'
  reject_text "$workflow" 'scripts/deploy/'
  reject_text "$workflow" 'ssh'
done

for workflow in "$user" "$node_server" "$publisher"; do
  reject_text "$workflow" 'workflow_dispatch:'
  reject_text "$workflow" 'cargo test'
  reject_text "$workflow" 'go test'
  reject_text "$workflow" 'make test'
  reject_text "$workflow" 'pnpm --dir web test'
  reject_text "$workflow" 'lint'
  reject_text "$workflow" 'cache-from:'
  reject_text "$workflow" 'cache-to:'
  reject_text "$workflow" 'actions/cache'
  reject_text "$workflow" 'upload-artifact'
  reject_text "$workflow" 'download-artifact'
done

require_text "$user_release" 'status --porcelain --untracked-files=all'
require_text "$user_release" 'unset GH_TOKEN GITHUB_TOKEN CONFIRM_DISPATCH CONFIRM_MUTATION'
require_text "$user_release" 'make --no-print-directory -C "$PROJECT_ROOT" validate'
require_text "$user_release" 'cargo fmt --all -- --check'
require_text "$user_release" 'make --no-print-directory -C "$ONE_USER_BACKEND_DIR" check'
require_text "$user_release" 'make --no-print-directory -C "$ONE_USER_BACKEND_DIR" test'
require_text "$user_release" 'make --no-print-directory -C "$ONE_USER_BACKEND_DIR" build'
require_text "$user_release" 'pnpm --dir "$ONE_USER_WEB_DIR" install --frozen-lockfile'
require_text "$user_release" 'pnpm --dir "$ONE_USER_WEB_DIR" test'
require_text "$user_release" 'control_tag="user-v$VERSION"'
require_text "$user_release" '"refs/tags/$control_tag:refs/tags/$control_tag"'

require_text "$node_server_release" 'status --porcelain --untracked-files=all'
require_text "$node_server_release" 'unset GH_TOKEN GITHUB_TOKEN CONFIRM_DISPATCH CONFIRM_MUTATION'
require_text "$node_server_release" 'make --no-print-directory -C "$PROJECT_ROOT" validate-node-server'
require_text "$node_server_release" 'make --no-print-directory -C "$ONE_NODE_WEB_DIR" install check build'
require_text "$node_server_release" 'make --no-print-directory -C "$ONE_NODE_SERVER_DIR" test'
require_text "$node_server_release" 'go vet ./...'
require_text "$node_server_release" 'make --no-print-directory -C "$ONE_NODE_SERVER_DIR" build \'
require_text "$node_server_release" 'HEAD must exactly match published origin/%s before triggering One Action.'
require_text "$node_server_release" 'format=one-node-server-release-v1'
require_text "$node_server_release" 'backend_sha=$server_head'
require_text "$node_server_release" 'web_sha=$web_head'
require_text "$node_server_release" 'tag -a "$control_tag" "$action_head" -m "$control_manifest"'
require_text "$node_server_release" 'control_tag="node-server-v$VERSION"'
require_text "$node_server_release" '"refs/tags/$control_tag:refs/tags/$control_tag"'
require_text "$node_server_release" 'Triggered One Node Server image publication and server deployment'
reject_text "$node_server_release" 'git -C "$ONE_NODE_SERVER_DIR" tag'
reject_text "$node_server_release" 'git -C "$ONE_NODE_WEB_DIR" tag'
reject_text "$node_server_release" 'document.version = process.env.VERSION;'

require_text "$node_server_deployer" '^ghcr\.io/voiceofhu/node-server:'
require_text "$node_server_deployer" 'docker-compose.yml.next'
require_text "$node_server_deployer" '"http://127.0.0.1:$published_port/api/healthz"'
require_text "$node_server_deployer" '"$public_url/api/healthz"'
require_text "$node_server_deployer" '"$public_url/"'
require_text "$node_server_deployer" 'attempting to restore the previous container'

printf '%s\n' 'Active GHCR publication workflow contracts passed.'
