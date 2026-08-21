#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

active_tests=(
  "$PROJECT_ROOT/tests/checksum-helper_test.sh"
  "$PROJECT_ROOT/tests/ghcr-publish-workflows_test.sh"
  "$PROJECT_ROOT/tests/node-migration-contract_test.sh"
  "$PROJECT_ROOT/tests/user-release-version_test.sh"
)
shell_files=(
  "$PROJECT_ROOT/node/install.sh"
  "$PROJECT_ROOT/node/upgrade.sh"
  "$PROJECT_ROOT/node/uninstall.sh"
  "$PROJECT_ROOT/scripts/github/check-token.sh"
  "$PROJECT_ROOT/scripts/github/common.sh"
  "$PROJECT_ROOT/scripts/release/deploy-node-release.sh"
  "$PROJECT_ROOT/scripts/release/deploy-node-server-release.sh"
  "$PROJECT_ROOT/scripts/release/deploy-user-release.sh"
  "$PROJECT_ROOT/scripts/release/write-checksums.sh"
  "${active_tests[@]}"
  "$PROJECT_ROOT/tests/fakes/curl"
  "$PROJECT_ROOT/scripts/validate.sh"
)

for file in "${shell_files[@]}"; do
  [[ -f "$file" ]] || {
    printf 'Missing active shell file: %s\n' "$file" >&2
    exit 1
  }
done

bash -n "${shell_files[@]}"
shellcheck --severity=warning "${shell_files[@]}"

active_workflows=(
  user.yml
  node-server.yml
  node.yml
  reusable-publish-web-backend.yml
)
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
if grep -RniE "$legacy_name" \
  "$PROJECT_ROOT/.github" \
  "$PROJECT_ROOT/make" \
  "$PROJECT_ROOT/scripts" \
  "$PROJECT_ROOT/tests" \
  "$PROJECT_ROOT/Makefile" \
  "$PROJECT_ROOT/README.md"; then
  printf '%s\n' 'Legacy product naming is allowed only in MIGRATION-SOURCES.md.' >&2
  exit 1
fi

while IFS= read -r workflow; do
  line_count="$(wc -l < "$workflow")"
  if ((line_count >= 500)); then
    printf 'Workflow must stay below 500 lines: %s (%s lines)\n' \
      "$workflow" "$line_count" >&2
    exit 1
  fi
done < <(find "$PROJECT_ROOT/.github/workflows" -type f -name '*.yml' | LC_ALL=C sort)

for test_script in "${active_tests[@]}"; do
  bash "$test_script"
done
make --no-print-directory -C "$PROJECT_ROOT" node-check

printf '%s\n' 'Shell syntax and workflow YAML structure are valid.'
