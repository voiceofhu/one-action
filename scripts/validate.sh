#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n \
  "$PROJECT_ROOT/browser/egress/install.sh" \
  "$PROJECT_ROOT/browser/egress/uninstall.sh" \
  "$PROJECT_ROOT/node/install.sh" \
  "$PROJECT_ROOT/node/upgrade.sh" \
  "$PROJECT_ROOT/node/uninstall.sh" \
  "$PROJECT_ROOT/browser/egress/tests/egress-installers_test.sh" \
  "$PROJECT_ROOT/browser/egress/tests/fakes/"* \
  "$PROJECT_ROOT"/scripts/github/*.sh \
  "$PROJECT_ROOT"/scripts/release/*.sh \
  "$PROJECT_ROOT"/tests/*.sh \
  "$PROJECT_ROOT"/tests/fakes/* \
  "$PROJECT_ROOT/scripts/validate.sh"

shellcheck --severity=warning \
  "$PROJECT_ROOT/browser/egress/install.sh" \
  "$PROJECT_ROOT/browser/egress/uninstall.sh" \
  "$PROJECT_ROOT/node/install.sh" \
  "$PROJECT_ROOT/node/upgrade.sh" \
  "$PROJECT_ROOT/node/uninstall.sh" \
  "$PROJECT_ROOT/browser/egress/tests/egress-installers_test.sh" \
  "$PROJECT_ROOT/browser/egress/tests/fakes/"* \
  "$PROJECT_ROOT/scripts/github/"*.sh \
  "$PROJECT_ROOT/scripts/release/"*.sh \
  "$PROJECT_ROOT/tests/"*.sh \
  "$PROJECT_ROOT/tests/fakes/"*

ruby -ryaml -e '
  required = %w[name on jobs]
  Dir[File.join(ARGV.fetch(0), ".github/workflows/*.yml")].sort.each do |file|
    document = YAML.safe_load(File.read(file), aliases: true)
    abort("#{file}: workflow must be a mapping") unless document.is_a?(Hash)
    missing = required.reject { |key| document.key?(key) }
    abort("#{file}: missing keys: #{missing.join(", ")}") unless missing.empty?
  end
' "$PROJECT_ROOT"

for workflow in one-user.yml one-browser-backend.yml app.yml app-debug.yml egress.yml browser-runtime.yml one-amz.yml node.yml; do
  [[ -f "$PROJECT_ROOT/.github/workflows/$workflow" ]] || {
    printf 'Missing required workflow: %s\n' "$workflow" >&2
    exit 1
  }
done

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

for reusable in reusable-prepare.yml reusable-build-web-backend.yml reusable-build-rust-docker.yml reusable-build-node.yml \
  reusable-build-app.yml reusable-build-app-debug.yml reusable-publish-web-backend.yml \
  reusable-publish-rust-docker.yml reusable-publish-egress.yml; do
  [[ -f "$PROJECT_ROOT/.github/workflows/$reusable" ]] || {
    printf 'Missing required reusable workflow: %s\n' "$reusable" >&2
    exit 1
  }
done

while IFS= read -r workflow; do
  line_count="$(wc -l < "$workflow")"
  if ((line_count >= 500)); then
    printf 'Workflow must stay below 500 lines: %s (%s lines)\n' \
      "$workflow" "$line_count" >&2
    exit 1
  fi
done < <(find "$PROJECT_ROOT/.github/workflows" -type f -name '*.yml' | LC_ALL=C sort)

bash "$PROJECT_ROOT/tests/checksum-helper_test.sh"
bash "$PROJECT_ROOT/tests/dispatch-dry-run_test.sh"
bash "$PROJECT_ROOT/tests/combined-build-workflows_test.sh"
bash "$PROJECT_ROOT/tests/rust-docker-workflows_test.sh"
bash "$PROJECT_ROOT/tests/ghcr-publish-workflows_test.sh"
bash "$PROJECT_ROOT/tests/app-build-workflows_test.sh"
bash "$PROJECT_ROOT/browser/egress/tests/egress-installers_test.sh"
bash "$PROJECT_ROOT/tests/egress-release-workflow_test.sh"
bash "$PROJECT_ROOT/tests/node-migration-contract_test.sh"
make --no-print-directory -C "$PROJECT_ROOT" node-check

printf '%s\n' 'Shell syntax and workflow YAML structure are valid.'
