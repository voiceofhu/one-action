#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
user_workflow="$PROJECT_ROOT/.github/workflows/pay-server.yml"
publisher="$PROJECT_ROOT/.github/workflows/reusable-publish-server-image.yml"
release="$PROJECT_ROOT/scripts/release/deploy-pay-release.sh"
deployer="$PROJECT_ROOT/scripts/deploy/deploy-pay.sh"

require_text() {
  local file=$1 text=$2
  grep -Fq -- "$text" "$file" || {
    printf 'Missing One Pay publication contract in %s: %s\n' "${file##*/}" "$text" >&2
    exit 1
  }
}

reject_text() {
  local file=$1 text=$2
  if grep -Fq -- "$text" "$file"; then
    printf 'Unexpected One Pay publication contract in %s: %s\n' "${file##*/}" "$text" >&2
    exit 1
  fi
}

for file in "$user_workflow" "$publisher" "$release" "$deployer"; do
  [[ -f "$file" ]] || {
    printf 'Missing One Pay publication file: %s\n' "$file" >&2
    exit 1
  }
done

ruby -ryaml -e '
  user = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
  trigger = user.fetch("on")
  abort("One Pay workflow must be dispatch-only") unless
    trigger.keys == ["workflow_dispatch"]
  inputs = trigger.fetch("workflow_dispatch").fetch("inputs")
  expected_inputs = %w[backend_ref backend_repository confirmation expected_action_sha publish version web_ref web_repository]
  abort("unexpected One Pay dispatch inputs") unless inputs.keys.sort == expected_inputs
  abort("unexpected One Pay jobs") unless user.fetch("jobs").keys.sort == %w[deploy prepare publish]
  abort("One Pay prepare timeout changed") unless
    user.fetch("jobs").fetch("prepare").fetch("timeout-minutes") <= 2
  deploy = user.fetch("jobs").fetch("deploy")
  abort("One Pay deploy must wait for prepare and publish") unless
    deploy.fetch("needs") == ["prepare", "publish"]
  abort("One Pay deploy environment changed") unless
    deploy.fetch("environment").fetch("name") == "one-pay-prod"
  abort("One Pay deploy concurrency changed") unless
    deploy.fetch("concurrency") == {
      "group" => "one-pay-prod-deploy", "cancel-in-progress" => false
    }

  publisher = YAML.safe_load(File.read(ARGV.fetch(1)), aliases: true)
  matrix = publisher.fetch("jobs").fetch("build").fetch("strategy").fetch("matrix").fetch("include")
  expected = [
    {"arch" => "amd64", "platform" => "linux/amd64", "runner" => "ubuntu-24.04"},
    {"arch" => "arm64", "platform" => "linux/arm64", "runner" => "ubuntu-24.04-arm"}
  ]
  abort("unexpected shared publisher matrix") unless matrix == expected
' "$user_workflow" "$publisher"

for text in \
  'workflow_name: one-pay' \
  'backend_sha: ${{ needs.prepare.outputs.backend_sha }}' \
  'web_sha: ${{ needs.prepare.outputs.web_sha }}' \
  'name: Deploy One Pay image' \
  'name: one-pay-prod' \
  'group: one-pay-prod-deploy' \
  "REMOTE_DIR: \${{ vars.DEPLOY_REMOTE_DIR || '/opt/one-pay' }}" \
  'DOCKER_IMAGE: ${{ needs.publish.outputs.image_ref }}' \
  'COMPOSE_FILE: backend/deploy/docker/docker-compose.yml' \
  "PUBLIC_URL: \${{ vars.DEPLOY_URL || 'https://pay.aicbe.com' }}" \
  'run: exec bash action/scripts/deploy/deploy-pay.sh'; do
  require_text "$user_workflow" "$text"
done

for text in \
  '^ghcr\.io/voiceofhu/one-pay:' \
  'docker-compose.yml.next' \
  '"http://127.0.0.1:$published_port/health/ready"' \
  '"$public_url/health/ready"' \
  '"$public_url/"' \
  'attempting to restore the previous container'; do
  require_text "$deployer" "$text"
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
  'make --no-print-directory -C "$PROJECT_ROOT" validate-pay' \
  'cargo fmt --all -- --check' \
  'make --no-print-directory -C "$ONE_PAY_BACKEND_DIR" test' \
  'pnpm --dir "$ONE_PAY_WEB_DIR" install --frozen-lockfile' \
  'pnpm --dir "$ONE_PAY_WEB_DIR" lint' \
  'pnpm --dir "$ONE_PAY_WEB_DIR" build' \
  'bash "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh" pay-server.yml' \
  '"backend_ref=$backend_release_sha"' \
  '"web_ref=$web_release_sha"'; do
  require_text "$release" "$text"
done

if grep -Fxq 'make --no-print-directory -C "$PROJECT_ROOT" validate' "$release"; then
  printf '%s\n' 'One Pay release must not invoke the full validation scope.' >&2
  exit 1
fi
reject_text "$release" 'make --no-print-directory -C "$ONE_PAY_BACKEND_DIR" check'
reject_text "$release" 'make --no-print-directory -C "$ONE_PAY_BACKEND_DIR" build'
reject_text "$release" 'git -C "$ONE_PAY_BACKEND_DIR" tag'
reject_text "$release" 'git -C "$ONE_PAY_WEB_DIR" tag'
reject_text "$release" 'git -C "$PROJECT_ROOT" tag'

printf '%s\n' 'One Pay focused publication workflow contract passed.'
