#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
scope=${1:-all}

case "$scope" in
  all)
    active_tests=(
      "$PROJECT_ROOT/tests/checksum-helper_test.sh"
      "$PROJECT_ROOT/tests/browser-egress-release-contract_test.sh"
      "$PROJECT_ROOT/tests/ghcr-publish-workflows_test.sh"
      "$PROJECT_ROOT/tests/node-migration-contract_test.sh"
      "$PROJECT_ROOT/node/tests/tuning_test.sh"
      "$PROJECT_ROOT/tests/node-server-publish-workflow_test.sh"
      "$PROJECT_ROOT/tests/node-server-trigger-only_test.sh"
      "$PROJECT_ROOT/tests/user-publish-workflow_test.sh"
      "$PROJECT_ROOT/tests/user-release-version_test.sh"
    )
    shell_files=(
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
      "$PROJECT_ROOT/scripts/deploy/deploy-user.sh"
      "$PROJECT_ROOT/scripts/deploy/registry-auth.sh"
      "$PROJECT_ROOT/scripts/release/deploy-node-release.sh"
      "$PROJECT_ROOT/scripts/release/deploy-browser-egress-release.sh"
      "$PROJECT_ROOT/scripts/release/deploy-node-server-release.sh"
      "$PROJECT_ROOT/scripts/release/deploy-user-release.sh"
      "$PROJECT_ROOT/scripts/release/write-checksums.sh"
      "${active_tests[@]}"
      "$PROJECT_ROOT/tests/fakes/curl"
      "$PROJECT_ROOT/scripts/validate.sh"
      "$PROJECT_ROOT/node/tests/firewall_test.sh"
      "$PROJECT_ROOT/node/tests/tuning_test.sh"
    )
    active_workflows=(
      user.yml
      egress.yml
      node-server.yml
      node.yml
      reusable-publish-web-backend.yml
    )
    run_node_check=true
    ;;
  user)
    active_tests=(
      "$PROJECT_ROOT/tests/user-publish-workflow_test.sh"
    )
    shell_files=(
      "$PROJECT_ROOT/scripts/deploy/configure-ssh.sh"
      "$PROJECT_ROOT/scripts/deploy/deploy-user.sh"
      "$PROJECT_ROOT/scripts/deploy/registry-auth.sh"
      "$PROJECT_ROOT/scripts/release/deploy-user-release.sh"
      "${active_tests[@]}"
      "$PROJECT_ROOT/scripts/validate.sh"
    )
    active_workflows=(
      user.yml
      reusable-publish-web-backend.yml
    )
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
      node.yml
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
      reusable-publish-web-backend.yml
    )
    run_node_check=false
    ;;
  browser-egress)
    active_tests=(
      "$PROJECT_ROOT/tests/browser-egress-release-contract_test.sh"
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
      egress.yml
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

legacy_name='aic''be'
canonical_user_origin="https://oa.${legacy_name}.com"
legacy_matches="$(
  grep -RniE "$legacy_name" \
    "$PROJECT_ROOT/.github" \
    "$PROJECT_ROOT/make" \
    "$PROJECT_ROOT/scripts" \
    "$PROJECT_ROOT/tests" \
    "$PROJECT_ROOT/Makefile" \
    "$PROJECT_ROOT/README.md" || true
)"
unexpected_legacy_matches="$(
  printf '%s\n' "$legacy_matches" \
    | sed "s#${canonical_user_origin}##g" \
    | grep -iE "$legacy_name" || true
)"
if [[ -n "$unexpected_legacy_matches" ]]; then
  printf '%s\n' "$unexpected_legacy_matches"
  printf '%s\n' \
    'Legacy product naming is allowed only in MIGRATION-SOURCES.md or the canonical One User origin.' >&2
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
  bash "$test_script"
done
if [[ "$run_node_check" == true ]]; then
  make --no-print-directory -C "$PROJECT_ROOT" node-check
fi

printf 'Shell syntax and %s workflow contracts are valid.\n' "$scope"
