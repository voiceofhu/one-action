#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
scope=${1:-all}
test_args=()

case "$scope" in
  all)
    active_tests=(
      "$PROJECT_ROOT/tests/products_test.sh"
      "$PROJECT_ROOT/tests/release-server_test.sh"
      "$PROJECT_ROOT/tests/release-web_test.sh"
      "$PROJECT_ROOT/tests/deploy-server_test.sh"
      "$PROJECT_ROOT/tests/deploy-web_test.sh"
      "$PROJECT_ROOT/tests/workflow-naming_test.sh"
      "$PROJECT_ROOT/tests/app-release_test.sh"
      "$PROJECT_ROOT/tests/browser-web-trigger-only_test.sh"
      "$PROJECT_ROOT/tests/browser-web-deploy_test.sh"
      "$PROJECT_ROOT/tests/browser-server-publish-workflow_test.sh"
      "$PROJECT_ROOT/tests/browser-server-trigger-only_test.sh"
      "$PROJECT_ROOT/tests/node-web-publish-workflow_test.sh"
      "$PROJECT_ROOT/tests/node-web-trigger-only_test.sh"
      "$PROJECT_ROOT/tests/node-web-deploy_test.sh"
      "$PROJECT_ROOT/tests/checksum-helper_test.sh"
      "$PROJECT_ROOT/tests/browser-egress-release-contract_test.sh"
      "$PROJECT_ROOT/tests/egress-updater_test.sh"
      "$PROJECT_ROOT/tests/ghcr-publish-workflows_test.sh"
      "$PROJECT_ROOT/tests/node-migration-contract_test.sh"
      "$PROJECT_ROOT/node/tests/tuning_test.sh"
      "$PROJECT_ROOT/tests/node-server-publish-workflow_test.sh"
      "$PROJECT_ROOT/tests/node-server-trigger-only_test.sh"
    )
    shell_files=(
      "$PROJECT_ROOT/scripts/lib/product.sh"
      "$PROJECT_ROOT/scripts/lib/git-remote.sh"
      "$PROJECT_ROOT/scripts/release/release-server.sh"
      "$PROJECT_ROOT/scripts/release/release-web.sh"
      "$PROJECT_ROOT/scripts/deploy/deploy-server.sh"
      "$PROJECT_ROOT/scripts/deploy/deploy-web.sh"
      "$PROJECT_ROOT/install.sh"
      "$PROJECT_ROOT/uninstall.sh"
      "$PROJECT_ROOT/egress/install.sh"
      "$PROJECT_ROOT/egress/uninstall.sh"
      "$PROJECT_ROOT"/egress/scripts/install/*.sh
      "$PROJECT_ROOT"/egress/scripts/uninstall/*.sh
      "$PROJECT_ROOT/node/install.sh"
      "$PROJECT_ROOT/node/scripts/install/firewall.sh"
      "$PROJECT_ROOT/node/scripts/install/tuning.sh"
      "$PROJECT_ROOT/node/upgrade.sh"
      "$PROJECT_ROOT/node/uninstall.sh"
      "$PROJECT_ROOT/scripts/github/check-token.sh"
      "$PROJECT_ROOT/scripts/github/common.sh"
      "$PROJECT_ROOT/scripts/deploy/configure-ssh.sh"
      "$PROJECT_ROOT/scripts/deploy/deploy-node-server.sh"
      "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh"
      "$PROJECT_ROOT/scripts/deploy/registry-auth.sh"
      "$PROJECT_ROOT/scripts/release/deploy-node-release.sh"
      "$PROJECT_ROOT/scripts/lib/app.sh"
      "$PROJECT_ROOT/scripts/release/release-app.sh"
      "$PROJECT_ROOT/scripts/release/deploy-browser-egress-release.sh"
      "$PROJECT_ROOT/scripts/release/deploy-node-server-release.sh"
      "$PROJECT_ROOT/scripts/release/write-checksums.sh"
      "${active_tests[@]}"
      "$PROJECT_ROOT/tests/fakes/curl"
      "$PROJECT_ROOT/scripts/validate.sh"
      "$PROJECT_ROOT/node/tests/firewall_test.sh"
      "$PROJECT_ROOT/node/tests/tuning_test.sh"
    )
    active_workflows=()
    for workflow_path in "$PROJECT_ROOT"/.github/workflows/*.yml; do
      active_workflows+=("${workflow_path##*/}")
    done
    run_node_check=true
    ;;
  amz|amz-web|mail|mail-web|notify|notify-web|object|object-web|pay|pay-web|template|template-web|user|user-web|vps|vps-web)
    active_tests=(
      "$PROJECT_ROOT/tests/products_test.sh"
      "$PROJECT_ROOT/tests/release-server_test.sh"
      "$PROJECT_ROOT/tests/release-web_test.sh"
      "$PROJECT_ROOT/tests/deploy-server_test.sh"
      "$PROJECT_ROOT/tests/deploy-web_test.sh"
    )
    shell_files=(
      "$PROJECT_ROOT/scripts/deploy/configure-ssh.sh"
      "$PROJECT_ROOT/scripts/lib/product.sh"
      "$PROJECT_ROOT/scripts/lib/git-remote.sh"
      "$PROJECT_ROOT/scripts/release/release-server.sh"
      "$PROJECT_ROOT/scripts/release/release-web.sh"
      "$PROJECT_ROOT/scripts/deploy/deploy-server.sh"
      "$PROJECT_ROOT/scripts/deploy/deploy-web.sh"
      "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh"
      "$PROJECT_ROOT/scripts/deploy/registry-auth.sh"
      "${active_tests[@]}"
      "$PROJECT_ROOT/scripts/validate.sh"
    )
    active_workflows=(
      reusable-deploy-server.yml
      reusable-deploy-web.yml
      reusable-publish-server-image.yml
    )
    # Only the product being released: the shared tests take its key.
    product_key=${scope%-web}
    test_args=("$product_key")
    active_workflows+=("$product_key-server.yml" "$product_key-web.yml")
    run_node_check=false
    ;;
  node)
    active_tests=(
      "$PROJECT_ROOT/tests/node-migration-contract_test.sh"
      "$PROJECT_ROOT/node/tests/firewall_test.sh"
      "$PROJECT_ROOT/node/tests/tuning_test.sh"
    )
    shell_files=(
      "$PROJECT_ROOT/node/scripts/install/firewall.sh"
      "$PROJECT_ROOT/node/scripts/install/tuning.sh"
      "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh"
      "$PROJECT_ROOT/scripts/release/deploy-node-release.sh"
      "${active_tests[@]}"
      "$PROJECT_ROOT/tests/fakes/curl"
      "$PROJECT_ROOT/scripts/validate.sh"
    )
    active_workflows=(
      node-runtime.yml
    )
    run_node_check=true
    ;;
  node-server)
    active_tests=(
      "$PROJECT_ROOT/tests/node-server-publish-workflow_test.sh"
      "$PROJECT_ROOT/tests/node-server-trigger-only_test.sh"
    )
    shell_files=(
      "$PROJECT_ROOT/scripts/deploy/configure-ssh.sh"
      "$PROJECT_ROOT/scripts/deploy/deploy-node-server.sh"
      "$PROJECT_ROOT/scripts/deploy/registry-auth.sh"
      "$PROJECT_ROOT/scripts/release/deploy-node-server-release.sh"
      "${active_tests[@]}"
      "$PROJECT_ROOT/scripts/validate.sh"
    )
    active_workflows=(
      node-server.yml
      reusable-publish-server-image.yml
    )
    run_node_check=false
    ;;
  node-web)
    active_tests=(
      "$PROJECT_ROOT/tests/node-web-publish-workflow_test.sh"
      "$PROJECT_ROOT/tests/node-web-trigger-only_test.sh"
      "$PROJECT_ROOT/tests/node-web-deploy_test.sh"
    )
    shell_files=(
      "$PROJECT_ROOT/scripts/release/deploy-node-web-release.sh"
      "$PROJECT_ROOT/scripts/deploy/deploy-node-web.sh"
      "$PROJECT_ROOT/scripts/deploy/deploy-node-server.sh"
      "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh"
      "${active_tests[@]}"
    )
    active_workflows=(node-web.yml node-server.yml)
    run_node_check=false
    ;;
  browser-app|mail-app)
    active_tests=("$PROJECT_ROOT/tests/app-release_test.sh")
    shell_files=(
      "$PROJECT_ROOT/scripts/lib/app.sh"
      "$PROJECT_ROOT/scripts/release/release-app.sh"
      "${active_tests[@]}"
    )
    active_workflows=(reusable-publish-tauri-app.yml)
    for app in $(jq -r 'keys[]' "$PROJECT_ROOT/apps.json"); do
      active_workflows+=("$app-app.yml")
    done
    run_node_check=false
    ;;
  browser-server)
    active_tests=("$PROJECT_ROOT/tests/browser-server-publish-workflow_test.sh" "$PROJECT_ROOT/tests/browser-server-trigger-only_test.sh" "$PROJECT_ROOT/tests/browser-web-trigger-only_test.sh" "$PROJECT_ROOT/tests/browser-web-deploy_test.sh")
    shell_files=(
      "$PROJECT_ROOT/scripts/release/deploy-browser-server-release.sh"
      "$PROJECT_ROOT/scripts/deploy/deploy-browser-server.sh"
      "$PROJECT_ROOT/scripts/deploy/deploy-browser-web.sh"
      "$PROJECT_ROOT/scripts/release/deploy-browser-web-release.sh"
      "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh"
      "${active_tests[@]}"
    )
    active_workflows=(browser-server.yml browser-web.yml reusable-publish-server-image.yml)
    run_node_check=false
    ;;
  browser-egress)
    active_tests=(
      "$PROJECT_ROOT/tests/browser-egress-release-contract_test.sh"
      "$PROJECT_ROOT/tests/egress-updater_test.sh"
    )
    shell_files=(
      "$PROJECT_ROOT/egress/install.sh"
      "$PROJECT_ROOT/egress/uninstall.sh"
      "$PROJECT_ROOT"/egress/scripts/install/*.sh
      "$PROJECT_ROOT"/egress/scripts/uninstall/*.sh
      "$PROJECT_ROOT/scripts/github/dispatch-workflow.sh"
      "$PROJECT_ROOT/scripts/release/deploy-browser-egress-release.sh"
      "${active_tests[@]}"
      "$PROJECT_ROOT/tests/fakes/curl"
      "$PROJECT_ROOT/scripts/validate.sh"
    )
    active_workflows=(
      browser-egress.yml
    )
    run_node_check=false
    ;;
  *)
    printf 'Unknown validation scope: %s\n' "$scope" >&2
    exit 1
    ;;
esac

for file in "${shell_files[@]}"; do
  [[ -f "$file" ]] || {
    printf 'Missing active shell file: %s\n' "$file" >&2
    exit 1
  }
done

bash -n "${shell_files[@]}"
shellcheck --severity=warning "${shell_files[@]}"

for workflow in "${active_workflows[@]}"; do
  [[ -f "$PROJECT_ROOT/.github/workflows/$workflow" ]] || {
    printf 'Missing required workflow: %s\n' "$workflow" >&2
    exit 1
  }
done

ruby -ryaml -e '
  required = %w[name on jobs]
  ARGV.each do |file|
    document = YAML.safe_load(File.read(file), aliases: true)
    abort("#{file}: workflow must be a mapping") unless document.is_a?(Hash)
    missing = required.reject { |key| document.key?(key) }
    abort("#{file}: missing keys: #{missing.join(", ")}") unless missing.empty?
    abort("#{file}: name must be a non-empty string") unless
      document["name"].is_a?(String) && !document["name"].empty?
    abort("#{file}: on must be a mapping") unless document["on"].is_a?(Hash)
    abort("#{file}: jobs must be a non-empty mapping") unless
      document["jobs"].is_a?(Hash) && !document["jobs"].empty?
  end
' "${active_workflows[@]/#/$PROJECT_ROOT/.github/workflows/}"

for tool in actionlint zizmor; do
  command -v "$tool" >/dev/null || {
    printf '%s is required for workflow checks: brew install actionlint zizmor\n' "$tool" >&2
    exit 1
  }
done
active_workflow_paths=("${active_workflows[@]/#/$PROJECT_ROOT/.github/workflows/}")
actionlint -config-file "$PROJECT_ROOT/.github/actionlint.yaml" "${active_workflow_paths[@]}"
env -u GH_TOKEN -u GITHUB_TOKEN -u ZIZMOR_GITHUB_TOKEN zizmor --offline --quiet --config "$PROJECT_ROOT/.github/zizmor.yml" "${active_workflow_paths[@]}"

legacy_name='aic''be'
# Canonical public origins: every products.json product plus One Browser.
canonical_origins=("https://browser.${legacy_name}.com")
while IFS= read -r origin; do
  canonical_origins+=("$origin")
done < <(jq -r '.[].public_url' "$PROJECT_ROOT/products.json")
legacy_matches="$(
  grep -RniE "$legacy_name" \
    "$PROJECT_ROOT/.github" \
    "$PROJECT_ROOT/make" \
    "$PROJECT_ROOT/scripts" \
    "$PROJECT_ROOT/tests" \
    "$PROJECT_ROOT/Makefile" \
    "$PROJECT_ROOT/README.md" || true
)"
for origin in "${canonical_origins[@]}"; do
  legacy_matches="${legacy_matches//"$origin"/}"
done
unexpected_legacy_matches="$(printf '%s\n' "$legacy_matches" | grep -iE "$legacy_name" || true)"
if [[ -n "$unexpected_legacy_matches" ]]; then
  printf '%s\n' "$unexpected_legacy_matches"
  printf '%s\n' \
    'Legacy product naming is allowed only in MIGRATION-SOURCES.md or the canonical origins in products.json (plus One Browser).' >&2
  exit 1
fi

while IFS= read -r workflow; do
  line_count="$(wc -l < "$workflow")"
  if ((line_count >= 500)); then
    printf 'Workflow must stay below 500 lines: %s (%s lines)\n' \
      "$workflow" "$line_count" >&2
    exit 1
  fi
done < <(printf '%s\n' "${active_workflows[@]/#/$PROJECT_ROOT/.github/workflows/}")

for test_script in "${active_tests[@]}"; do
  bash "$test_script" ${test_args[@]+"${test_args[@]}"}
done
if [[ "$run_node_check" == true ]]; then
  make --no-print-directory -C "$PROJECT_ROOT" node-check
fi

printf 'Shell syntax and %s workflow contracts are valid.\n' "$scope"
