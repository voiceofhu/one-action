#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
app_caller="$PROJECT_ROOT/.github/workflows/app.yml"
debug_caller="$PROJECT_ROOT/.github/workflows/app-debug.yml"
app_build="$PROJECT_ROOT/.github/workflows/reusable-build-app.yml"
debug_build="$PROJECT_ROOT/.github/workflows/reusable-build-app-debug.yml"

require_text() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || {
    printf 'Missing required workflow text in %s: %s\n' "$file" "$text" >&2
    exit 1
  }
}

for caller in "$app_caller" "$debug_caller"; do
  require_text "$caller" 'name: Reject mutable or privileged App'
  require_text "$caller" 'runs-on: ubuntu-24.04'
  require_text "$caller" 'permissions: {}'
  require_text "$caller" 'needs: policy'
  require_text "$caller" '[ "$ACTION_REPOSITORY" = voiceofhu/one-action ]'
  require_text "$caller" '[ "$APP_REPOSITORY" = voiceofhu/one-browser-app-next ]'
  require_text "$caller" '[[ ! "$EXPECTED_ACTION_SHA" =~ ^[0-9a-f]{40}$ ]]'
  require_text "$caller" 'Dispatcher-bound Action SHA is missing, invalid, or stale.'
  require_text "$caller" '[[ "$APP_REF" =~ ^[0-9a-f]{40}$ ]]'
  require_text "$caller" 'refusing before source resolution'
  require_text "$caller" 'reject mutation confirmation input'
  require_text "$caller" 'needs: prepare'
  require_text "$caller" 'app_sha: ${{ needs.prepare.outputs.primary_sha }}'
  require_text "$caller" 'action_sha: ${{ github.sha }}'
  if grep -Fq 'secrets: inherit' "$caller"; then
    printf 'App caller unexpectedly inherits repository secrets: %s\n' "$caller" >&2
    exit 1
  fi
done
require_text "$app_caller" 'uses: ./.github/workflows/reusable-build-app.yml'
require_text "$app_caller" 'publish: ${{ inputs.publish }}'
require_text "$debug_caller" 'uses: ./.github/workflows/reusable-build-app-debug.yml'
require_text "$debug_caller" 'upload_artifact: ${{ inputs.upload_artifact }}'

for build in "$app_build" "$debug_build"; do
  require_text "$build" 'permissions:'
  require_text "$build" 'contents: read'
  require_text "$build" '[ "$ACTION_REPOSITORY" = voiceofhu/one-action ]'
  require_text "$build" '[ "$APP_REPOSITORY" = voiceofhu/one-browser-app-next ]'
  require_text "$build" 'ref: ${{ inputs.app_sha }}'
  require_text "$build" 'token: ${{ github.token }}'
  require_text "$build" 'persist-credentials: false'
  require_text "$build" 'git -C "$directory" rev-parse --verify HEAD'
  require_text "$build" 'App build-control file is missing or symlinked'
  require_text "$build" 'app/pnpm-lock.yaml'
  require_text "$build" 'app/src-tauri/Cargo.lock'
  require_text "$build" 'node-version: 24.0.0'
  require_text "$build" 'version: 10.32.1'
  require_text "$build" 'pnpm install --frozen-lockfile'
  require_text "$build" 'pnpm exec prettier --check "**/*.{ts,tsx}"'
  require_text "$build" 'pnpm lint'
  require_text "$build" 'pnpm typecheck'
  require_text "$build" 'pnpm build'
  require_text "$build" 'cargo fmt --manifest-path src-tauri/Cargo.toml --all -- --check'
  require_text "$build" 'cargo check --manifest-path src-tauri/Cargo.toml --locked'
  require_text "$build" 'cargo clippy --manifest-path src-tauri/Cargo.toml --locked --all-targets -- -D warnings'
  require_text "$build" 'cargo test --manifest-path src-tauri/Cargo.toml --locked'
  require_text "$build" 'test -f src-tauri/tauri.conf.json'
  require_text "$build" '--no-sign'
  require_text "$build" 'action/scripts/release/write-checksums.sh'
  require_text "$build" 'provenance/manifest.json'
  require_text "$build" 'uploaded: false'
  require_text "$build" 'published: false'
  require_text "$build" 'Provenance and SHA256SUMS: generated in the runner'
  require_text "$build" 'uses: dtolnay/rust-toolchain@1.97.1'
  require_text "$build" "while IFS= read -r -d ''"
  require_text "$build" 'cargo metadata --manifest-path app/src-tauri/Cargo.toml --no-deps --locked'
  require_text "$build" 'App package, Tauri, and Cargo versions must match exactly.'
  require_text "$build" 'Exact App source version is not canonical.'
  require_text "$build" 'APP_SOURCE_VERSION=%s'
  require_text "$build" 'MAX_BINARY_BYTES=536870912'
  require_text "$build" 'MAX_INSTALLER_BYTES=2147483648'
  require_text "$build" 'is missing, not regular, or symlinked.'
  require_text "$build" 'provenance destination must be create-new.'
  require_text "$build" 'Verify source identity after build'
  require_text "$build" 'git -C "$directory" diff --quiet --no-ext-diff --ignore-submodules --'
  require_text "$build" '(.path | contains("..") | not)'
  require_text "$build" '.app.repository == "voiceofhu/one-browser-app-next"'
  require_text "$build" '(.version | test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))'
  require_text "$build" 'uploaded == false'
  require_text "$build" 'published == false'
done

require_text "$app_build" 'runner: macos-14'
require_text "$app_build" 'expected_arch: arm64'
require_text "$app_build" 'bundle: dmg'
require_text "$app_build" 'runner: windows-2022'
require_text "$app_build" 'expected_arch: x64'
require_text "$app_build" 'bundle: nsis'
require_text "$app_build" "if: runner.os == 'macOS'"
require_text "$app_build" "if: runner.os == 'Windows'"
require_text "$app_build" 'shell: pwsh'
require_text "$app_build" 'pnpm exec tauri build --bundles "$BUNDLE" --ci --no-sign'
require_text "$app_build" 'app/src-tauri/target/release/one-browser-app'
require_text "$app_build" 'app/src-tauri/target/release/one-browser-app.exe'
require_text "$app_build" "pattern='*.dmg'"
require_text "$app_build" "pattern='*.exe'"
require_text "$app_build" 'Expected exactly one Tauri installer.'
require_text "$app_build" 'length == 2'

require_text "$debug_build" 'pnpm exec tauri build --debug --bundles nsis --ci --no-sign'
require_text "$debug_build" 'app/src-tauri/target/debug/one-browser-app.exe'
require_text "$debug_build" 'runs-on: windows-2022'
require_text "$debug_build" 'shell: pwsh'
require_text "$debug_build" "-name '*.exe'"
require_text "$debug_build" 'app/src-tauri/target/debug/one-browser-app.pdb'
require_text "$debug_build" 'MAX_PDB_BYTES=2147483648'
require_text "$debug_build" 'Expected exactly one Debug NSIS installer.'
require_text "$debug_build" 'length == 3'
require_text "$debug_build" 'endswith("/one-browser-app.pdb")'

for build in "$app_build" "$debug_build"; do
  frontend_line="$(grep -nF 'pnpm build' "$build" | head -1 | cut -d: -f1)"
  rust_line="$(grep -nF 'cargo test --manifest-path src-tauri/Cargo.toml --locked' "$build" | cut -d: -f1)"
  tauri_line="$(grep -nF 'pnpm exec tauri build' "$build" | cut -d: -f1)"
  provenance_line="$(grep -nF 'provenance/manifest.json' "$build" | head -1 | cut -d: -f1)"
  if ! ((frontend_line < rust_line && rust_line < tauri_line && tauri_line < provenance_line)); then
    printf 'App build stages are out of order in %s.\n' "$build" >&2
    exit 1
  fi

  if grep -Eq 'inputs\.app_ref' "$build"; then
    printf 'App build consumes a mutable ref: %s\n' "$build" >&2
    exit 1
  fi
  if grep -Eq 'mapfile|sort -z|dtolnay/rust-toolchain@stable|node-version:[[:space:]]*(latest|24)$|windows-latest' "$build"; then
    printf 'App build uses a drifting toolchain or Bash 4-only mapfile: %s\n' "$build" >&2
    exit 1
  fi
  if grep -Eq 'actions/upload-artifact|tauri-apps/tauri-action|gh release|docker (login|push)|codesign|signtool|APPLE_SIGNING_IDENTITY|secrets\.(GH_TOKEN|source_read_token)|packages:[[:space:]]*write|contents:[[:space:]]*write|id-token:[[:space:]]*write' "$build"; then
    printf 'App build unexpectedly uploads, publishes, signs, or pushes: %s\n' "$build" >&2
    exit 1
  fi
done

if grep -Eq 'production-devtools|tauri\.ci\.conf|tauri\.macos\.conf' "$debug_build"; then
  printf '%s\n' 'Debug workflow copied a legacy-only source command.' >&2
  exit 1
fi

printf '%s\n' 'App build workflow contract tests passed.'
